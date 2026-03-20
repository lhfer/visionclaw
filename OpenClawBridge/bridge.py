#!/usr/bin/env python3
"""
ShrimpXR OpenClaw Bridge v2
============================
Dual-relay: Vision Pro ↔ Bridge ↔ OpenClaw Gateway

- WebSocket Server (port 8765) for Vision Pro
- Spawns openclaw_auth.js as subprocess to connect to OpenClaw Gateway
- Relays messages bidirectionally with status mapping
"""

import asyncio
import json
import logging
import signal
import os
import sys
import uuid
from datetime import datetime

try:
    import websockets
except ImportError:
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install", "websockets"])
    import websockets

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(levelname)s %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("bridge")

WS_PORT = 8765
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
AUTH_SCRIPT = os.path.join(SCRIPT_DIR, "openclaw_auth.js")


class OpenClawRelay:
    """Manages the openclaw_auth.js subprocess for gateway communication."""

    def __init__(self, on_event):
        self.on_event = on_event  # callback for events from OpenClaw
        self.process = None
        self.authenticated = False
        self.writer = None

    async def start(self):
        """Start the openclaw_auth.js subprocess."""
        node_path = "/opt/homebrew/bin/node"
        if not os.path.exists(node_path):
            node_path = "node"

        env = {
            **os.environ,
            "NO_PROXY": "*",
            "PATH": f"/opt/homebrew/bin:{os.environ.get('PATH', '')}",
            "NODE_PATH": "/opt/homebrew/lib/node_modules",
        }

        log.info("Starting OpenClaw auth subprocess...")
        self.process = await asyncio.create_subprocess_exec(
            node_path, AUTH_SCRIPT, "connect",
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=env,
        )
        self.writer = self.process.stdin

        # Read stdout (JSON messages from auth.js)
        asyncio.create_task(self._read_stdout())
        asyncio.create_task(self._read_stderr())

    async def _read_stdout(self):
        """Read JSON messages from openclaw_auth.js stdout."""
        while True:
            line = await self.process.stdout.readline()
            if not line:
                log.warning("OpenClaw auth process ended")
                self.authenticated = False
                await self.on_event({"type": "status", "status": "idle"})
                # Auto-restart after delay
                await asyncio.sleep(3)
                await self.start()
                return
            try:
                msg = json.loads(line.decode().strip())
                await self._handle_message(msg)
            except json.JSONDecodeError:
                pass

    async def _read_stderr(self):
        """Log stderr from openclaw_auth.js."""
        while True:
            line = await self.process.stderr.readline()
            if not line:
                return
            log.info(f"[openclaw] {line.decode().strip()}")

    async def _handle_message(self, msg):
        """Process a message from openclaw_auth.js."""
        msg_type = msg.get("type")

        if msg_type == "auth_ok":
            self.authenticated = True
            log.info(f"OpenClaw authenticated! scopes={msg.get('scopes')}")
            await self.on_event({
                "type": "status_check_result",
                "openclaw_available": True,
            })

        elif msg_type == "auth_failed":
            self.authenticated = False
            log.error(f"OpenClaw auth failed: {msg.get('message')}")
            await self.on_event({
                "type": "status_check_result",
                "openclaw_available": False,
            })

        elif msg_type == "event" and msg.get("event") == "chat":
            # Chat response from OpenClaw → map to shrimp states
            payload = msg.get("payload", {})
            state = payload.get("state")
            content = payload.get("message", {}).get("content", [])
            text = ""
            for block in content:
                if block.get("type") == "text":
                    text += block.get("text", "")

            if state == "delta":
                # Streaming text → shrimp is "working"
                await self.on_event({"type": "status", "status": "working"})
                if text:
                    await self.on_event({
                        "type": "chat_delta",
                        "text": text,
                        "runId": payload.get("runId"),
                    })

            elif state == "final":
                # Final response → send result
                log.info(f"OpenClaw response: {text[:100]}...")
                await self.on_event({
                    "type": "result",
                    "success": True,
                    "text": text,
                    "taskId": payload.get("runId", datetime.now().isoformat()),
                })

            elif state == "error":
                error_msg = payload.get("errorMessage", "Unknown error")
                log.error(f"OpenClaw error: {error_msg}")
                await self.on_event({
                    "type": "result",
                    "success": False,
                    "text": f"出错了: {error_msg}",
                    "taskId": payload.get("runId", datetime.now().isoformat()),
                })

        elif msg_type == "res":
            # Response to our chat.send request
            req_id = msg.get("id", "")
            if req_id.startswith("chat-"):
                if msg.get("ok"):
                    log.info("chat.send accepted by OpenClaw")
                    await self.on_event({"type": "status", "status": "thinking"})
                else:
                    error = msg.get("error", {})
                    log.error(f"chat.send failed: {error.get('message', 'unknown')}")
                    await self.on_event({
                        "type": "result",
                        "success": False,
                        "text": f"发送失败: {error.get('message', 'unknown')}",
                        "taskId": datetime.now().isoformat(),
                    })

        elif msg_type == "disconnected":
            self.authenticated = False
            log.warning("OpenClaw disconnected")

    async def send_chat(self, message: str, session_key: str = "shrimpxr"):
        """Send a chat message to OpenClaw."""
        if not self.authenticated:
            log.warning("Not authenticated, cannot send chat")
            return False

        cmd = json.dumps({
            "type": "chat.send",
            "message": message,
            "sessionKey": session_key,
            "idempotencyKey": str(uuid.uuid4()),
        }) + "\n"

        self.writer.write(cmd.encode())
        await self.writer.drain()
        log.info(f"Sent to OpenClaw: {message[:80]}")
        return True

    async def check_status(self):
        """Check if OpenClaw connection is alive."""
        return self.authenticated


class BridgeServer:
    """WebSocket server for Vision Pro clients."""

    def __init__(self):
        self.clients: set = set()
        self.openclaw = OpenClawRelay(on_event=self._on_openclaw_event)
        self._last_delta_text = ""

    async def start(self):
        """Start both the OpenClaw relay and the WebSocket server."""
        await self.openclaw.start()

    async def handler(self, websocket):
        """Handle a Vision Pro WebSocket connection."""
        self.clients.add(websocket)
        addr = websocket.remote_address
        log.info(f"Vision Pro connected: {addr}")

        try:
            async for message in websocket:
                await self._handle_client_message(websocket, message)
        except websockets.exceptions.ConnectionClosed:
            log.info(f"Vision Pro disconnected: {addr}")
        finally:
            self.clients.discard(websocket)

    async def _handle_client_message(self, ws, raw: str):
        """Handle a message from Vision Pro."""
        try:
            msg = json.loads(raw)
        except json.JSONDecodeError:
            return

        msg_type = msg.get("type")

        if msg_type == "task":
            content = msg.get("content", "").strip()
            if content:
                self._last_delta_text = ""
                # Notify Vision Pro: thinking
                await self._send(ws, {"type": "status", "status": "thinking"})
                # Send to OpenClaw
                ok = await self.openclaw.send_chat(content)
                if not ok:
                    await self._send(ws, {
                        "type": "result",
                        "success": False,
                        "text": "OpenClaw 未连接，请稍后重试",
                        "taskId": datetime.now().isoformat(),
                    })

        elif msg_type == "ping":
            await self._send(ws, {"type": "pong"})

        elif msg_type == "status_check":
            available = await self.openclaw.check_status()
            await self._send(ws, {
                "type": "status_check_result",
                "openclaw_available": available,
            })

    async def _on_openclaw_event(self, event):
        """Forward an event from OpenClaw to all Vision Pro clients."""
        event_type = event.get("type")

        # For delta events, accumulate text and send periodic updates
        if event_type == "chat_delta":
            self._last_delta_text = event.get("text", "")
            # Don't flood Vision Pro with every delta, just status
            await self._broadcast({"type": "status", "status": "working"})
            return

        # For result events, send the final accumulated text
        if event_type == "result":
            # Send idle status after result
            await self._broadcast(event)
            await asyncio.sleep(0.1)
            await self._broadcast({"type": "status", "status": "idle"})
            return

        await self._broadcast(event)

    async def _broadcast(self, data):
        """Send to all connected Vision Pro clients."""
        msg = json.dumps(data, ensure_ascii=False)
        for client in self.clients.copy():
            try:
                await client.send(msg)
            except websockets.exceptions.ConnectionClosed:
                self.clients.discard(client)

    async def _send(self, ws, data):
        """Send to a specific client."""
        try:
            await ws.send(json.dumps(data, ensure_ascii=False))
        except websockets.exceptions.ConnectionClosed:
            pass


# --- Bonjour ---

def advertise_bonjour(port):
    try:
        from zeroconf import ServiceInfo, Zeroconf
        import socket
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(("8.8.8.8", 80))
            local_ip = s.getsockname()[0]
            s.close()
        except Exception:
            local_ip = "127.0.0.1"

        info = ServiceInfo(
            "_shrimpxr._tcp.local.",
            "ShrimpXR Bridge._shrimpxr._tcp.local.",
            addresses=[socket.inet_aton(local_ip)],
            port=port,
            properties={"version": "2.0", "name": "ShrimpXR"},
        )
        zc = Zeroconf()
        zc.register_service(info)
        log.info(f"Bonjour: ShrimpXR Bridge at {local_ip}:{port}")
        return zc, info
    except Exception as e:
        log.warning(f"Bonjour failed: {e}")
        return None, None


# --- Main ---

async def main():
    server = BridgeServer()

    # Start Bonjour
    zc, info = advertise_bonjour(WS_PORT)

    # Start OpenClaw relay
    await server.start()

    # Start WebSocket server
    stop = asyncio.get_event_loop().create_future()

    def shutdown(*_):
        if not stop.done():
            stop.set_result(None)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    async with websockets.serve(server.handler, "0.0.0.0", WS_PORT):
        log.info(f"ShrimpXR Bridge v2 running on ws://0.0.0.0:{WS_PORT}")
        log.info("Waiting for Vision Pro to connect...")
        await stop

    if zc and info:
        zc.unregister_service(info)
        zc.close()
    log.info("Bridge stopped.")


if __name__ == "__main__":
    asyncio.run(main())
