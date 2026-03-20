#!/usr/bin/env node
/**
 * OpenClaw Gateway Authentication Helper
 *
 * Generates device identity, connects to OpenClaw gateway using the webchat protocol,
 * and provides an authenticated WebSocket connection for the bridge.
 *
 * This runs as a child process of bridge.py, outputting JSON messages to stdout.
 */

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

// Load gateway token from OpenClaw config
function loadConfig() {
  const configPath = path.join(process.env.HOME, ".openclaw", "openclaw.json");
  try {
    const raw = fs.readFileSync(configPath, "utf8");
    return JSON.parse(raw);
  } catch (e) {
    console.error(`Failed to read OpenClaw config: ${e.message}`);
    process.exit(1);
  }
}

// Generate or load persistent device identity
function loadOrCreateDeviceIdentity() {
  const identityPath = path.join(process.env.HOME, ".openclaw", "shrimpxr-device.json");

  if (fs.existsSync(identityPath)) {
    const saved = JSON.parse(fs.readFileSync(identityPath, "utf8"));
    return saved;
  }

  // Generate ED25519 keypair (same as OpenClaw's generateIdentity)
  const { publicKey, privateKey } = crypto.generateKeyPairSync("ed25519");
  const publicKeyPem = publicKey.export({ type: "spki", format: "pem" }).toString();
  const privateKeyPem = privateKey.export({ type: "pkcs8", format: "pem" }).toString();

  // Derive device ID same way as OpenClaw: sha256(raw SPKI DER bytes)
  const spkiDer = publicKey.export({ type: "spki", format: "der" });
  // ED25519 SPKI prefix
  const ED25519_PREFIX = Buffer.from("302a300506032b6570032100", "hex");
  let rawKey;
  if (spkiDer.length === ED25519_PREFIX.length + 32 &&
      spkiDer.subarray(0, ED25519_PREFIX.length).equals(ED25519_PREFIX)) {
    rawKey = spkiDer.subarray(ED25519_PREFIX.length);
  } else {
    rawKey = spkiDer;
  }
  const deviceId = crypto.createHash("sha256").update(rawKey).digest("hex");

  // Base64URL encode raw key for transmission
  const pubB64Url = rawKey.toString("base64").replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/g, "");

  const identity = { publicKey: publicKeyPem, privateKey: privateKeyPem, pubB64Url, deviceId };
  fs.writeFileSync(identityPath, JSON.stringify(identity, null, 2));
  console.error(`[auth] Created new device identity: ${deviceId.substring(0, 16)}...`);

  return identity;
}

// Base64URL encode (same as OpenClaw's implementation)
function base64UrlEncode(buf) {
  return buf.toString("base64").replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/g, "");
}

// Sign v3 auth payload using ED25519
function signPayload(device, params) {
  const { clientId, clientMode, role, scopes, signedAt, token, nonce } = params;
  const scopesStr = scopes.join(",");
  const payload = [
    "v3", device.deviceId, clientId, clientMode, role, scopesStr,
    String(signedAt), token || "", nonce, "darwin", ""
  ].join("|");

  const key = crypto.createPrivateKey(device.privateKey);
  const sig = crypto.sign(null, Buffer.from(payload, "utf8"), key);
  return base64UrlEncode(sig);
}

// Verify our own signature (sanity check)
function verifySelfSignature(device, payloadStr, signature) {
  const key = crypto.createPublicKey(device.publicKey);
  // Decode base64url signature
  const normalized = signature.replaceAll("-", "+").replaceAll("_", "/");
  const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
  const sig = Buffer.from(padded, "base64");
  return crypto.verify(null, Buffer.from(payloadStr, "utf8"), key, sig);
}

async function main() {
  const config = loadConfig();
  const gwConfig = config.gateway || {};
  const token = gwConfig.auth?.token || "";
  const port = gwConfig.port || 18789;
  const device = loadOrCreateDeviceIdentity();

  const mode = process.argv[2] || "connect";

  if (mode === "info") {
    // Just output device info
    const output = {
      type: "device_info",
      deviceId: device.deviceId,
      gatewayPort: port,
      hasToken: !!token,
    };
    console.log(JSON.stringify(output));
    return;
  }

  if (mode === "connect") {
    // Connect to gateway and relay messages via stdin/stdout
    let WebSocket;
    try {
      WebSocket = require("ws").WebSocket;
    } catch {
      // Try global
      const globalPath = require("child_process")
        .execSync("npm root -g", { encoding: "utf8" }).trim();
      WebSocket = require(path.join(globalPath, "ws")).WebSocket;
    }

    const url = `ws://127.0.0.1:${port}`;
    console.error(`[auth] Connecting to OpenClaw gateway at ${url}...`);

    const ws = new WebSocket(url, {
      headers: { Origin: `http://127.0.0.1:${port}` },
    });

    let authenticated = false;
    let reqIdCounter = 0;

    ws.on("open", () => {
      console.error("[auth] WebSocket connected, waiting for challenge...");
    });

    ws.on("message", (data) => {
      const msg = JSON.parse(data.toString());

      // Handle challenge
      if (msg.event === "connect.challenge") {
        const nonce = msg.payload.nonce;
        const ts = msg.payload.ts;
        const scopes = ["operator.admin", "operator.read", "operator.write"];
        const clientId = "webchat";
        const clientMode = "webchat";
        const role = "operator";

        const signature = signPayload(device, {
          clientId, clientMode, role, scopes, signedAt: ts, token, nonce,
        });

        // Verify our own signature before sending
        const payloadStr = [
          "v3", device.deviceId, clientId, clientMode, role, scopes.join(","),
          String(ts), token || "", nonce, "darwin", ""
        ].join("|");
        const selfVerify = verifySelfSignature(device, payloadStr, signature);
        console.error(`[auth] Self-verify: ${selfVerify}`);

        ws.send(JSON.stringify({
          type: "req",
          id: "connect-1",
          method: "connect",
          params: {
            minProtocol: 3,
            maxProtocol: 3,
            client: {
              id: clientId,
              displayName: "ShrimpXR",
              version: "1.0.0",
              platform: "darwin",
              mode: clientMode,
            },
            role,
            scopes,
            auth: { token },
            device: {
              id: device.deviceId,
              publicKey: device.pubB64Url,
              signature,
              signedAt: ts,
              nonce,
            },
          },
        }));
        return;
      }

      // Handle connect response
      if (msg.type === "res" && msg.id === "connect-1") {
        if (msg.ok) {
          authenticated = true;
          const auth = msg.payload?.auth || {};
          console.error(`[auth] AUTHENTICATED! scopes=${JSON.stringify(auth.scopes)} role=${auth.role}`);

          // Store device token if provided
          if (auth.deviceToken) {
            const identityPath = path.join(process.env.HOME, ".openclaw", "shrimpxr-device.json");
            const identity = JSON.parse(fs.readFileSync(identityPath, "utf8"));
            identity.deviceToken = auth.deviceToken;
            fs.writeFileSync(identityPath, JSON.stringify(identity, null, 2));
            console.error("[auth] Saved device token for future connections");
          }

          // Notify bridge that we're ready
          console.log(JSON.stringify({
            type: "auth_ok",
            scopes: auth.scopes || [],
            role: auth.role || "operator",
            connId: msg.payload?.server?.connId,
          }));
        } else {
          const err = msg.error || {};
          console.error(`[auth] Auth FAILED: ${err.code} - ${err.message}`);
          console.log(JSON.stringify({
            type: "auth_failed",
            code: err.code,
            message: err.message,
            details: err.details,
          }));

          // If NOT_PAIRED, we need pairing approval
          if (err.code === "NOT_PAIRED" || err.details?.code === "DEVICE_IDENTITY_REQUIRED") {
            console.error("[auth] Device needs pairing. Run: openclaw device pair approve <device-id>");
          }
        }
        return;
      }

      // Forward all other messages (chat events, responses) to bridge via stdout
      if (authenticated) {
        console.log(JSON.stringify(msg));
      }
    });

    // Read commands from stdin (from bridge.py)
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => {
      const lines = chunk.trim().split("\n");
      for (const line of lines) {
        try {
          const cmd = JSON.parse(line);
          if (cmd.type === "chat.send") {
            reqIdCounter++;
            ws.send(JSON.stringify({
              type: "req",
              id: `chat-${reqIdCounter}`,
              method: "chat.send",
              params: {
                sessionKey: cmd.sessionKey || "shrimpxr",
                message: cmd.message,
                idempotencyKey: cmd.idempotencyKey || crypto.randomUUID(),
              },
            }));
          }
        } catch (e) {
          console.error(`[auth] Invalid stdin input: ${e.message}`);
        }
      }
    });

    ws.on("error", (e) => {
      console.error(`[auth] WebSocket error: ${e.message}`);
      console.log(JSON.stringify({ type: "error", message: e.message }));
    });

    ws.on("close", (code, reason) => {
      console.error(`[auth] WebSocket closed: ${code} ${reason}`);
      console.log(JSON.stringify({ type: "disconnected", code }));
      process.exit(0);
    });

    // Keep alive
    setInterval(() => {
      if (ws.readyState === ws.OPEN) {
        ws.ping();
      }
    }, 15000);
  }
}

main().catch((e) => {
  console.error(`[auth] Fatal: ${e.message}`);
  process.exit(1);
});
