# ── Codex Azure Proxy Setup for Windows ──────────────────────────────
# Fill in your Azure credentials below before running:
$AZURE_KEY  = "YOUR_AZURE_API_KEY_HERE"
$AZURE_BASE = "YOUR_AZURE_BASE_URL_HERE"
$AZURE_VER  = "2025-04-01-preview"
$PROXY_DIR  = "$env:USERPROFILE\.codex\proxy"
$CODEX_CFG  = "$env:USERPROFILE\.codex\config.toml"

if ($AZURE_KEY -eq "YOUR_AZURE_API_KEY_HERE") {
    Write-Host "ERROR: Please fill in AZURE_KEY and AZURE_BASE at the top of this script."
    exit 1
}

Write-Host "[1/5] Creating proxy directory..."
New-Item -ItemType Directory -Force -Path $PROXY_DIR | Out-Null
New-Item -ItemType Directory -Force -Path "$PROXY_DIR\certs" | Out-Null

Write-Host "[2/5] Writing proxy.js..."
$PROXY_JS = @'
"use strict";
const net = require("node:net");
const tls = require("node:tls");
const https = require("node:https");
const fs = require("node:fs");
const { URL } = require("node:url");

const PORT = Number(process.env.PROXY_PORT) || 8765;
const CERTS_DIR = process.env.CERTS_DIR || "/Users/balloon/codex-proxy/certs";
const AZURE_BASE = process.env.AZURE_BASE_URL || "https://binl-mdi7xat3-eastus2.services.ai.azure.com/openai";
const AZURE_KEY = process.env.OPENAI_API_KEY || "";
const AZURE_API_VERSION = process.env.AZURE_API_VERSION || "2025-04-01-preview";
const TARGET_HOST = "api.openai.com";

var fakeCert, fakeKey;
try {
  fakeCert = fs.readFileSync(CERTS_DIR + "/api.openai.com.crt");
  fakeKey  = fs.readFileSync(CERTS_DIR + "/api.openai.com.key");
} catch(e) {
  // Certs not required for direct connection mode (base_url in config.toml)
}

function log() {
  var args = Array.prototype.slice.call(arguments);
  args.unshift(new Date().toISOString());
  args.unshift("[proxy]");
  console.error.apply(console, args);
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

// Direct pass-through: forward Codex Responses API request to Azure Responses API.
// Azure supports native Responses API at $AZURE_BASE/responses?api-version=2025-04-01-preview.
// SSE event format is byte-for-byte identical to OpenAI — no conversion needed.
function handleOpenAIRequest(reqBody, socket, modelOverride, done) {
  var model = modelOverride || reqBody.model || "gpt-5.5";
  var inputLen = Array.isArray(reqBody.input) ? reqBody.input.length : (reqBody.input ? 1 : 0);
  var hasPrevId = !!reqBody.previous_response_id;
  log("request: model=" + model + " input_items=" + inputLen + " prev_id=" + hasPrevId);

  // Forward request body as-is, only override model and ensure stream=true
  var azureBody = Object.assign({}, reqBody, { model: model, stream: true });
  var azureUrl = new URL(AZURE_BASE + "/responses");
  azureUrl.searchParams.set("api-version", AZURE_API_VERSION);
  var bodyStr = JSON.stringify(azureBody);

  log("-> Azure", azureUrl.pathname + azureUrl.search, "model=" + model);

  var AZURE_TIMEOUT_MS = 60000;
  var azReq = https.request({
    hostname: azureUrl.hostname,
    port: 443,
    path: azureUrl.pathname + azureUrl.search,
    method: "POST",
    timeout: AZURE_TIMEOUT_MS,
    headers: {
      "Content-Type": "application/json",
      "Content-Length": Buffer.byteLength(bodyStr),
      "api-key": AZURE_KEY,
    },
  }, function(azRes) {
    log("<- Azure status=" + azRes.statusCode);

    if (azRes.statusCode !== 200) {
      var errData = "";
      azRes.on("data", function(d) { errData += d; });
      azRes.on("end", function() {
        log("Azure error:", errData.slice(0, 300));
        var respId = "resp_err_" + Date.now();
        writeSSEHeaders(socket, 200);
        sendEvent(socket, "response.completed", {
          response: { id: respId, status: "incomplete", error: { code: "api_error", message: errData } },
        });
        done();
      });
      return;
    }

    // Write HTTP headers to client then pipe Azure SSE bytes straight through.
    // Azure Responses API SSE format is identical to OpenAI — no conversion needed.
    writeSSEHeaders(socket, 200);
    azRes.on("data", function(chunk) {
      socket.write(chunk);
    });
    azRes.on("end", function() {
      log("Done: stream ended model=" + model);
      done();
    });
    azRes.on("error", function(e) { log("stream error:", e.message); done(e); });
  });

  azReq.on("timeout", function() {
    log("Azure request timed out after " + (AZURE_TIMEOUT_MS / 1000) + "s — sending error to Codex");
    azReq.destroy();
    var respId = "resp_timeout_" + Date.now();
    writeSSEHeaders(socket, 200);
    sendEvent(socket, "response.completed", {
      response: {
        id: respId, status: "incomplete",
        error: { code: "timeout", message: "Azure request timed out after " + (AZURE_TIMEOUT_MS / 1000) + "s" },
      },
    });
    done();
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
        JSON.stringify({ ok: true, proxy: "codex-azure-mitm-v4" })
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
          if (err) {
            log("handler error:", err.message || err);
          }
          clearSocket.end();
        });
      } catch(e) {
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
    clientSocket.write("HTTP/1.1 200 Connection Established" + CRLF +
      "Proxy-Agent: codex-azure-proxy" + CRLF + CRLF);
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
      // Plain HTTP proxy request (Clash Party forwards as HTTP, not CONNECT tunnel)
      // target may be full URL like "https://api.openai.com/v1/responses" or just "/responses"
      log("plain-HTTP:", method, target);

      // Parse path from full URL if needed
      var plainPath = target;
      if (target && target.indexOf("://") !== -1) {
        try {
          plainPath = new (require("node:url").URL)(target).pathname;
        } catch(e) { plainPath = target; }
      }

      var isResponses = plainPath === "/v1/responses" || plainPath === "/responses" ||
        /^\/openai\/deployments\/[^/]+\/responses$/.test(plainPath) ||
        /^\/deployments\/[^/]+\/responses$/.test(plainPath);

      if (method === "POST" && isResponses) {
        // Parse full request with body
        var allLines = header.split("\r\n");
        var plainHeaders = {};
        for (var hi = 1; hi < allLines.length; hi++) {
          var ci = allLines[hi].indexOf(":");
          if (ci === -1) continue;
          plainHeaders[allLines[hi].slice(0, ci).toLowerCase().trim()] = allLines[hi].slice(ci + 1).trim();
        }
        var plainCL = parseInt(plainHeaders["content-length"] || "0", 10);

        // Accumulate body then handle
        var bodyBuf = remaining;
        function tryHandlePlain() {
          if (bodyBuf.length < plainCL) return; // need more data
          clientSocket.removeListener("data", onBodyData);
          try {
            var reqBody = JSON.parse(bodyBuf.slice(0, plainCL || bodyBuf.length).toString("utf8"));
            handleOpenAIRequest(reqBody, clientSocket, null, function(err) {
              if (err) log("plain handler error:", err.message || err);
              clientSocket.end();
            });
          } catch(e) {
            log("plain parse error:", e.message);
            clientSocket.write("HTTP/1.1 500 Internal Server Error" + CRLF + "Connection: close" + CRLF + CRLF);
            clientSocket.end();
          }
        }
        function onBodyData(c) { bodyBuf = Buffer.concat([bodyBuf, c]); tryHandlePlain(); }
        clientSocket.on("data", onBodyData);
        tryHandlePlain();
        return;
      }

      // Unknown non-CONNECT request
      clientSocket.write("HTTP/1.1 400 Bad Request" + CRLF + CRLF);
      clientSocket.end();
      return;
    }

    var hostPort = target.split(":");
    var host = hostPort[0];
    var port = parseInt(hostPort[1] || "443", 10);

    log("CONNECT", host + ":" + port);

    if (host === TARGET_HOST && fakeCert && fakeKey) {
      clientSocket.write("HTTP/1.1 200 Connection Established" + CRLF +
        "Proxy-Agent: codex-azure-mitm" + CRLF + CRLF);

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
  log("Codex Azure MITM Proxy v4 on 127.0.0.1:" + PORT);
  log("Mode: direct Responses API pass-through (no format conversion)");
  log("Intercepting: " + TARGET_HOST);
  log("AZURE_BASE: " + AZURE_BASE);
  log("AZURE_KEY: " + (AZURE_KEY ? AZURE_KEY.slice(0, 8) + "..." : "(not set)"));
});

server.on("error", function(e) { log("Server error:", e.message); process.exit(1); });
process.on("SIGTERM", function() { server.close(); process.exit(0); });
process.on("SIGINT", function() { server.close(); process.exit(0); });

'@
[System.IO.File]::WriteAllText("$PROXY_DIR\proxy.js", $PROXY_JS, [System.Text.Encoding]::UTF8)
Write-Host "  Done: $PROXY_DIR\proxy.js"

Write-Host "[3/5] Updating config.toml..."
$TOML_HEADER = "model = `"gpt-5.5`"`r`nmodel_reasoning_effort = `"medium`"`r`nmodel_provider = `"azure-proxy`"`r`n`r`n[model_providers.azure-proxy]`r`nname = `"Azure OpenAI (via local proxy)`"`r`nbase_url = `"http://127.0.0.1:8765`"`r`nenv_key = `"OPENAI_API_KEY`"`r`nwire_api = `"responses`"`r`n`r`n"
if (Test-Path $CODEX_CFG) {
    $existing = [System.IO.File]::ReadAllText($CODEX_CFG)
    if ($existing -notmatch "azure-proxy") {
        [System.IO.File]::WriteAllText($CODEX_CFG, $TOML_HEADER + $existing, [System.Text.Encoding]::UTF8)
        Write-Host "  config.toml updated"
    } else { Write-Host "  config.toml already configured, skipped" }
} else {
    [System.IO.File]::WriteAllText($CODEX_CFG, $TOML_HEADER, [System.Text.Encoding]::UTF8)
    Write-Host "  config.toml created"
}

Write-Host "[4/5] Setting OPENAI_API_KEY..."
[System.Environment]::SetEnvironmentVariable("OPENAI_API_KEY", $AZURE_KEY, "User")
$env:OPENAI_API_KEY = $AZURE_KEY
Write-Host "  Set (user-level, persists across reboots)"

Write-Host "[5/5] Starting proxy and creating auto-start task..."
$node = (Get-Command node -ErrorAction SilentlyContinue)
if (-not $node) {
    Write-Host ""
    Write-Host "  !! Node.js not found. Install from https://nodejs.org/en/download (LTS)"
    Write-Host "  !! After installing, re-run this script."
    exit 1
}
$nodePath = $node.Source

$existing = Get-NetTCPConnection -LocalPort 8765 -ErrorAction SilentlyContinue
if ($existing) {
    $pid = ($existing | Select-Object -First 1).OwningProcess
    Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
    Write-Host "  Stopped previous proxy (PID $pid)"
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $nodePath
$psi.Arguments = "`"$PROXY_DIR\proxy.js`""
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.EnvironmentVariables["OPENAI_API_KEY"]      = $AZURE_KEY
$psi.EnvironmentVariables["AZURE_BASE_URL"]       = $AZURE_BASE
$psi.EnvironmentVariables["AZURE_API_VERSION"]    = $AZURE_VER
$psi.EnvironmentVariables["CERTS_DIR"]            = "$PROXY_DIR\certs"
$proc = [System.Diagnostics.Process]::Start($psi)
Start-Sleep 2
if ($proc -and !$proc.HasExited) {
    Write-Host "  Proxy running PID=$($proc.Id) on 127.0.0.1:8765"
} else {
    Write-Host "  !! Proxy failed to start. Check: node `"$PROXY_DIR\proxy.js`""
}

$action   = New-ScheduledTaskAction -Execute $nodePath -Argument "`"$PROXY_DIR\proxy.js`"" -WorkingDirectory $PROXY_DIR
$trigger  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -MultipleInstances IgnoreNew -Hidden
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName "CodexAzureProxy" -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Force | Out-Null
Write-Host "  Task 'CodexAzureProxy' registered (runs at logon)"

Write-Host ""
Write-Host "Setup complete! Restart Codex -> bottom right: 'Azure OpenAI (via local proxy)'"
