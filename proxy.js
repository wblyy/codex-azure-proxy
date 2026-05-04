"use strict";
const net = require("node:net");
const tls = require("node:tls");
const https = require("node:https");
const fs = require("node:fs");
const { URL } = require("node:url");

const PORT = Number(process.env.PROXY_PORT) || 8765;
const CERTS_DIR = process.env.CERTS_DIR || (process.env.HOME + "/codex-proxy/certs");
const AZURE_BASE = process.env.AZURE_BASE_URL || "";
const AZURE_KEY = process.env.OPENAI_API_KEY || "";
const AZURE_API_VERSION = process.env.AZURE_API_VERSION || "2025-04-01-preview";
const TARGET_HOST = "api.openai.com";

if (!AZURE_BASE) {
  console.error("[proxy] ERROR: AZURE_BASE_URL not set");
  process.exit(1);
}

const fakeCert = fs.readFileSync(CERTS_DIR + "/api.openai.com.crt");
const fakeKey  = fs.readFileSync(CERTS_DIR + "/api.openai.com.key");

function log() {
  var args = Array.prototype.slice.call(arguments);
  args.unshift(new Date().toISOString());
  args.unshift("[proxy]");
  console.error.apply(console, args);
}

// Convert Codex Responses API input[] to Azure Chat Completions messages[].
//
// Azure rules:
//   1. content:null only allowed when tool_calls is present
//   2. All parallel tool_calls from one turn MUST be in ONE assistant message
//   3. role:"tool" messages must immediately follow the assistant with matching tool_calls
//
// Real Codex input patterns (from proxy logs):
//   [fc1,fc2,fco1,fco2]           parallel tools
//   [text,fc,fco]                 text then tool in same output turn
//   [fc,text_msg,fco]             tool sandwiched by text — merge text into assistant
//   [fc1,fco1,text,fc2,fco2]      sequential rounds
//   [fc1,fc2,fco1,fco2,text,fc3]  mixed parallel + sequential
function inputToMessages(input, instructions) {
  var messages = [];
  if (instructions) messages.push({ role: "system", content: instructions });
  if (typeof input === "string") {
    messages.push({ role: "user", content: input });
  } else if (Array.isArray(input)) {
    for (var i = 0; i < input.length; i++) {
      var item = input[i];
      if (item.type === "function_call") {
        var tc = {
          id: item.call_id || item.id || ("call_" + i),
          type: "function",
          function: {
            name: item.name || "",
            arguments: typeof item.arguments === "string"
              ? item.arguments
              : JSON.stringify(item.arguments || {}),
          },
        };
        var lastMsg = messages.length > 0 ? messages[messages.length - 1] : null;
        if (lastMsg && lastMsg.role === "assistant") {
          // Merge into existing assistant (handles parallel FCs + sandwiched-text pattern)
          if (lastMsg.tool_calls) {
            lastMsg.tool_calls.push(tc);
          } else {
            lastMsg.tool_calls = [tc];
          }
        } else {
          messages.push({ role: "assistant", content: null, tool_calls: [tc] });
        }
      } else if (item.type === "function_call_output") {
        messages.push({
          role: "tool",
          tool_call_id: item.call_id || item.id || "unknown",
          content: typeof item.output === "string"
            ? item.output
            : JSON.stringify(item.output),
        });
      } else if (item.role === "assistant" && item.content) {
        var aContent = item.content;
        var textVal;
        if (Array.isArray(aContent)) {
          textVal = aContent.filter(function(c) {
            return c.type === "output_text" || c.type === "text" || typeof c === "string";
          }).map(function(c) {
            return typeof c === "string" ? c : (c.text || c.output || "");
          }).join("") || null;
        } else {
          textVal = typeof aContent === "string" ? aContent : null;
        }
        var lastMsgA = messages.length > 0 ? messages[messages.length - 1] : null;
        if (lastMsgA && lastMsgA.role === "assistant" && lastMsgA.tool_calls) {
          // Sandwiched text: merge content into the pending tool-call assistant message.
          // content:null is fine here since tool_calls is present.
          lastMsgA.content = textVal;
        } else {
          // Text-only assistant message — Azure requires content to be a non-null string.
          messages.push({ role: "assistant", content: textVal || "" });
        }
      } else if (item.role) {
        var content = item.content;
        if (Array.isArray(content)) {
          content = content.map(function(c) {
            return typeof c === "string" ? c : (c.text || c.value || "");
          }).join("");
        }
        messages.push({ role: item.role, content: content || "" });
      } else if (item.type === "message") {
        var content2 = item.content;
        if (Array.isArray(content2)) {
          content2 = content2.map(function(c) {
            return typeof c === "string" ? c : (c.text || c.value || "");
          }).join("");
        }
        messages.push({ role: item.role || "user", content: content2 || "" });
      }
    }
  }
  return messages;
}

function convertTools(tools) {
  if (!tools || !tools.length) return undefined;
  return tools.filter(function(t) {
    return t.type === "function" || t.name;
  }).map(function(t) {
    return {
      type: "function",
      function: {
        name: t.name || (t.function && t.function.name),
        description: t.description || (t.function && t.function.description) || "",
        parameters: t.parameters || (t.function && t.function.parameters) || {
          type: "object", properties: {},
        },
      },
    };
  });
}

var CRLF = "\r\n";

function writeSSEHeaders(socket, statusCode) {
  statusCode = statusCode || 200;
  socket.write(
    "HTTP/1.1 " + statusCode + " OK" + CRLF +
    "Content-Type: text/event-stream; charset=utf-8" + CRLF +
    "Cache-Control: no-cache" + CRLF +
    "Connection: keep-alive" + CRLF +
    CRLF
  );
}

function sendEvent(socket, type, data) {
  var obj = Object.assign({ type: type }, data);
  socket.write("data: " + JSON.stringify(obj) + "\n\n");
}

function handleOpenAIRequest(reqBody, socket, modelOverride, done) {
  var model = modelOverride || reqBody.model || "gpt-4o";

  // Log input structure for debugging
  if (Array.isArray(reqBody.input) && reqBody.input.length > 1) {
    var inputSummary = reqBody.input.map(function(it, idx) {
      return idx + ":" + (it.type || it.role || "?") +
        (it.name ? "(" + it.name + ")" : "") +
        (it.call_id ? "[" + it.call_id.slice(0, 8) + "]" : "");
    }).join(" ");
    log("input-items[" + reqBody.input.length + "]:", inputSummary);
  }

  var messages = inputToMessages(reqBody.input, reqBody.instructions);

  var msgSummary = messages.map(function(m) {
    return m.role +
      (m.tool_calls ? "(tc:" + m.tool_calls.length + ")" : "") +
      (m.tool_call_id ? "[" + m.tool_call_id.slice(0, 8) + "]" : "");
  }).join(" -> ");
  log("messages[" + messages.length + "]:", msgSummary);

  var tools = convertTools(reqBody.tools);

  var chatBody = {
    model: model,
    messages: messages,
    stream: true,
    max_completion_tokens: reqBody.max_output_tokens || reqBody.max_completion_tokens || 16000,
  };
  if (tools && tools.length) {
    chatBody.tools = tools;
    if (reqBody.tool_choice) chatBody.tool_choice = reqBody.tool_choice;
  }
  if (reqBody.reasoning_effort) chatBody.reasoning_effort = reqBody.reasoning_effort;
  if (reqBody.temperature !== undefined) chatBody.temperature = reqBody.temperature;

  var azureUrl = new URL(
    AZURE_BASE + "/deployments/" + encodeURIComponent(model) + "/chat/completions"
  );
  azureUrl.searchParams.set("api-version", AZURE_API_VERSION);
  var bodyStr = JSON.stringify(chatBody);

  log("-> Azure", azureUrl.pathname, "model=" + model, "msgs=" + messages.length);

  var azReq = https.request({
    hostname: azureUrl.hostname,
    port: 443,
    path: azureUrl.pathname + azureUrl.search,
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Content-Length": Buffer.byteLength(bodyStr),
      "api-key": AZURE_KEY,
    },
  }, function(azRes) {
    log("<- Azure status=" + azRes.statusCode);

    var respId = "resp_" + Date.now();
    var itemId = "msg_" + Date.now();

    writeSSEHeaders(socket, 200);

    if (azRes.statusCode !== 200) {
      var errData = "";
      azRes.on("data", function(d) { errData += d; });
      azRes.on("end", function() {
        log("Azure error:", errData);
        sendEvent(socket, "response.completed", {
          response: {
            id: respId, status: "incomplete",
            error: { code: "api_error", message: errData },
          },
        });
        done();
      });
      return;
    }

    sendEvent(socket, "response.created", {
      response: { id: respId, object: "realtime.response", status: "in_progress", model: model },
    });
    sendEvent(socket, "response.in_progress", {
      response: { id: respId, object: "realtime.response", status: "in_progress", model: model },
    });
    sendEvent(socket, "response.output_item.added", {
      response_id: respId, output_index: 0,
      item: { id: itemId, object: "realtime.item", type: "message", role: "assistant", content: [] },
    });
    sendEvent(socket, "response.content_part.added", {
      response_id: respId, item_id: itemId, output_index: 0, content_index: 0,
      part: { type: "output_text", text: "" },
    });

    var fullText = "";
    var toolCalls = {};
    var buf = "";

    azRes.on("data", function(chunk) {
      buf += chunk.toString();
      var lines = buf.split("\n");
      buf = lines.pop();
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i];
        if (line.indexOf("data: ") !== 0) continue;
        var data = line.slice(6).trim();
        if (data === "[DONE]") continue;
        var obj;
        try { obj = JSON.parse(data); } catch (e) { continue; }
        var choice = obj.choices && obj.choices[0];
        if (!choice) continue;
        var delta = choice.delta || {};
        if (delta.content) {
          fullText += delta.content;
          sendEvent(socket, "response.output_text.delta", {
            response_id: respId, item_id: itemId,
            output_index: 0, content_index: 0, delta: delta.content,
          });
        }
        if (delta.tool_calls) {
          for (var j = 0; j < delta.tool_calls.length; j++) {
            var tc = delta.tool_calls[j];
            var idx = tc.index !== undefined ? tc.index : 0;
            if (!toolCalls[idx]) {
              toolCalls[idx] = { id: "", type: "function", function: { name: "", arguments: "" } };
            }
            if (tc.id) toolCalls[idx].id = tc.id;
            if (tc.function && tc.function.name) toolCalls[idx].function.name += tc.function.name;
            if (tc.function && tc.function.arguments) {
              toolCalls[idx].function.arguments += tc.function.arguments;
            }
          }
        }
      }
    });

    azRes.on("end", function() {
      if (fullText) {
        sendEvent(socket, "response.output_text.done", {
          response_id: respId, item_id: itemId,
          output_index: 0, content_index: 0, text: fullText,
        });
        sendEvent(socket, "response.content_part.done", {
          response_id: respId, item_id: itemId, output_index: 0, content_index: 0,
          part: { type: "output_text", text: fullText },
        });
      }

      var tcList = Object.values(toolCalls);
      var outputItems = [];
      if (fullText) {
        outputItems.push({
          type: "message", id: itemId, role: "assistant",
          content: [{ type: "output_text", text: fullText }],
        });
        sendEvent(socket, "response.output_item.done", {
          response_id: respId, output_index: 0, item: outputItems[0],
        });
      } else {
        sendEvent(socket, "response.output_item.done", {
          response_id: respId, output_index: 0,
          item: { type: "message", id: itemId, role: "assistant", content: [] },
        });
      }

      for (var k = 0; k < tcList.length; k++) {
        var tc2 = tcList[k];
        var fcItem = {
          type: "function_call", id: tc2.id, call_id: tc2.id,
          name: tc2.function.name, arguments: tc2.function.arguments,
        };
        outputItems.push(fcItem);
        sendEvent(socket, "response.output_item.done", {
          response_id: respId, output_index: (fullText ? 1 : 0) + k, item: fcItem,
        });
      }

      sendEvent(socket, "response.completed", {
        response: {
          id: respId, object: "realtime.response", status: "completed", model: model,
          output: outputItems,
        },
      });

      log("Done: respId=" + respId + " text_len=" + fullText.length + " tools=" + tcList.length);
      done();
    });

    azRes.on("error", function(e) { log("stream error:", e.message); done(e); });
  });

  azReq.on("error", function(e) { log("az request error:", e.message); done(e); });
  azReq.write(bodyStr);
  azReq.end();
}

function parseHTTPRequest(buf) {
  var str = buf.toString("utf8");
  var headEnd = str.indexOf("\r\n\r\n");
  if (headEnd === -1) return null;

  var headerSection = str.slice(0, headEnd);
  var body = buf.slice(headEnd + 4);
  var lines = headerSection.split("\r\n");
  var firstLine = lines[0].split(" ");
  var method = firstLine[0];
  var rawPath = firstLine[1];

  var headers = {};
  for (var i = 1; i < lines.length; i++) {
    var colonIdx = lines[i].indexOf(":");
    if (colonIdx === -1) continue;
    var key = lines[i].slice(0, colonIdx).toLowerCase().trim();
    var val = lines[i].slice(colonIdx + 1).trim();
    headers[key] = val;
  }

  var contentLength = parseInt(headers["content-length"] || "0", 10);
  return { method: method, path: rawPath, headers: headers, body: body, contentLength: contentLength };
}

function handleMITMSocket(clearSocket) {
  log("TLS OK, waiting for HTTP...");
  var rawBuf = Buffer.alloc(0);

  clearSocket.on("data", function onData(chunk) {
    rawBuf = Buffer.concat([rawBuf, chunk]);
    var parsed = parseHTTPRequest(rawBuf);
    if (!parsed) return;
    if (parsed.body.length < parsed.contentLength) return;

    clearSocket.removeListener("data", onData);
    var method = parsed.method;
    var path = parsed.path;

    log("intercepted:", method, path);

    if (method === "GET" && path === "/health") {
      clearSocket.write(
        "HTTP/1.1 200 OK" + CRLF +
        "Content-Type: application/json" + CRLF +
        "Connection: close" + CRLF + CRLF +
        JSON.stringify({ ok: true, proxy: "codex-azure-mitm" })
      );
      clearSocket.end();
      return;
    }

    var isResponses = path === "/v1/responses" || path === "/responses" ||
      /^\/openai\/deployments\/[^/]+\/responses$/.test(path) ||
      /^\/deployments\/[^/]+\/responses$/.test(path);

    if (method === "POST" && isResponses) {
      try {
        var reqBody = JSON.parse(parsed.body.toString("utf8"));
        handleOpenAIRequest(reqBody, clearSocket, null, function(err) {
          if (err) log("handler error:", err.message || err);
          clearSocket.end();
        });
      } catch (e) {
        log("parse error:", e.message);
        clearSocket.write(
          "HTTP/1.1 500 Internal Server Error" + CRLF +
          "Content-Type: application/json" + CRLF +
          "Connection: close" + CRLF + CRLF +
          JSON.stringify({ error: { message: String(e) } })
        );
        clearSocket.end();
      }
      return;
    }

    log("404:", method, path);
    clearSocket.write("HTTP/1.1 404 Not Found" + CRLF + "Connection: close" + CRLF + CRLF);
    clearSocket.end();
  });

  clearSocket.on("error", function(e) { log("mitm socket error:", e.message); });
}

function tunnelDirect(clientSocket, host, port, head) {
  var target = net.connect(port, host, function() {
    clientSocket.write(
      "HTTP/1.1 200 Connection Established" + CRLF +
      "Proxy-Agent: codex-azure-proxy" + CRLF + CRLF
    );
    if (head && head.length > 0) target.write(head);
    target.pipe(clientSocket);
    clientSocket.pipe(target);
  });
  target.on("error", function(e) {
    log("tunnel error " + host + ":" + port + ":", e.message);
    clientSocket.end("HTTP/1.1 502 Bad Gateway" + CRLF + CRLF);
  });
  clientSocket.on("error", function() { target.destroy(); });
}

var server = net.createServer(function(clientSocket) {
  var rawHead = Buffer.alloc(0);

  function onData(chunk) {
    rawHead = Buffer.concat([rawHead, chunk]);
    var str = rawHead.toString("utf8");
    var headEnd = str.indexOf("\r\n\r\n");
    if (headEnd === -1) return;

    clientSocket.removeListener("data", onData);
    var header = str.slice(0, headEnd);
    var remaining = rawHead.slice(headEnd + 4);
    var firstLine = header.split("\r\n")[0];
    var parts = firstLine.split(" ");
    var method = parts[0];
    var target = parts[1];

    if (method !== "CONNECT") {
      // Plain HTTP proxy request (ClashX may forward as plain HTTP, not CONNECT)
      log("plain-HTTP:", method, target);

      var plainPath = target;
      if (target && target.indexOf("://") !== -1) {
        try { plainPath = new URL(target).pathname; } catch (e) { plainPath = target; }
      }

      var isResponsesPlain = plainPath === "/v1/responses" || plainPath === "/responses" ||
        /^\/openai\/deployments\/[^/]+\/responses$/.test(plainPath) ||
        /^\/deployments\/[^/]+\/responses$/.test(plainPath);

      if (method === "POST" && isResponsesPlain) {
        var allLines = header.split("\r\n");
        var plainHeaders = {};
        for (var hi = 1; hi < allLines.length; hi++) {
          var ci = allLines[hi].indexOf(":");
          if (ci === -1) continue;
          plainHeaders[allLines[hi].slice(0, ci).toLowerCase().trim()] =
            allLines[hi].slice(ci + 1).trim();
        }
        var plainCL = parseInt(plainHeaders["content-length"] || "0", 10);
        var bodyBuf = remaining;

        function tryHandlePlain() {
          if (bodyBuf.length < plainCL) return;
          clientSocket.removeListener("data", onBodyData);
          try {
            var reqBody = JSON.parse(
              bodyBuf.slice(0, plainCL || bodyBuf.length).toString("utf8")
            );
            handleOpenAIRequest(reqBody, clientSocket, null, function(err) {
              if (err) log("plain handler error:", err.message || err);
              clientSocket.end();
            });
          } catch (e) {
            log("plain parse error:", e.message);
            clientSocket.write(
              "HTTP/1.1 500 Internal Server Error" + CRLF + "Connection: close" + CRLF + CRLF
            );
            clientSocket.end();
          }
        }
        function onBodyData(c) { bodyBuf = Buffer.concat([bodyBuf, c]); tryHandlePlain(); }
        clientSocket.on("data", onBodyData);
        tryHandlePlain();
        return;
      }

      clientSocket.write("HTTP/1.1 400 Bad Request" + CRLF + CRLF);
      clientSocket.end();
      return;
    }

    var hostPort = target.split(":");
    var host = hostPort[0];
    var port = parseInt(hostPort[1] || "443", 10);

    log("CONNECT", host + ":" + port);

    if (host === TARGET_HOST) {
      clientSocket.write(
        "HTTP/1.1 200 Connection Established" + CRLF +
        "Proxy-Agent: codex-azure-mitm" + CRLF + CRLF
      );

      var tlsSock = new tls.TLSSocket(clientSocket, {
        isServer: true,
        cert: fakeCert,
        key: fakeKey,
      });

      tlsSock.on("error", function(e) { log("TLS error:", e.message); });
      tlsSock.on("secure", function() {
        log("TLS handshake OK");
        handleMITMSocket(tlsSock);
        if (remaining.length > 0) tlsSock.emit("data", remaining);
      });
    } else {
      tunnelDirect(clientSocket, host, port, remaining);
    }
  }

  clientSocket.on("data", onData);
  clientSocket.on("error", function(e) { log("client error:", e.message); });
});

server.listen(PORT, "127.0.0.1", function() {
  log("Codex Azure MITM Proxy on 127.0.0.1:" + PORT);
  log("Intercepting: " + TARGET_HOST);
  log("AZURE_BASE: " + AZURE_BASE);
  log("AZURE_KEY: " + (AZURE_KEY ? AZURE_KEY.slice(0, 8) + "..." : "(not set)"));
});

server.on("error", function(e) { log("Server error:", e.message); process.exit(1); });
process.on("SIGTERM", function() { server.close(); process.exit(0); });
process.on("SIGINT", function() { server.close(); process.exit(0); });
