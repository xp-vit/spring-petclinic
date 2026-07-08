#!/usr/bin/env python3
"""Fixed-delay HTTP stub for the virtual-thread benchmark.

Stands in for a slow external API. `GET /delay/<ms>` sleeps for <ms> milliseconds and then
returns 200. Built on asyncio so the stub itself is NEVER the thread bottleneck: a single
event loop handles thousands of concurrent in-flight delays. If the stub were thread-per-
request it would saturate first and we'd be benchmarking the stub, not the app.

No third-party dependencies (stdlib asyncio only) so it runs in a slim python image.

Env:
  PORT        listen port (default 9090)
  MAX_DELAY   clamp on requested delay in ms (default 60000) - safety valve
"""
import asyncio
import os

PORT = int(os.environ.get("PORT", "9090"))
MAX_DELAY = int(os.environ.get("MAX_DELAY", "60000"))

BODY = b"ok"


async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    # Serve multiple requests per connection (HTTP/1.1 keep-alive) so clients that pool
    # connections (e.g. the JDK HttpClient behind Spring's RestClient) don't pay a fresh
    # TCP handshake per request under high concurrency.
    try:
        while True:
            request_line = await reader.readline()
            if not request_line:
                return  # peer closed
            # Drain the rest of the request headers.
            while True:
                line = await reader.readline()
                if line in (b"\r\n", b"\n", b""):
                    break

            parts = request_line.split()
            delay_ms = 0
            status = b"200 OK"
            if len(parts) >= 2:
                path = parts[1].decode("latin1", "replace")
                # /delay/<ms>  or  /delay?ms=<ms>
                raw = None
                if path.startswith("/delay/"):
                    raw = path[len("/delay/"):].split("?", 1)[0]
                elif path.startswith("/delay") and "ms=" in path:
                    raw = path.split("ms=", 1)[1].split("&", 1)[0]
                elif path in ("/", "/health"):
                    raw = "0"
                if raw is not None:
                    try:
                        delay_ms = max(0, min(int(raw), MAX_DELAY))
                    except ValueError:
                        status = b"400 Bad Request"
                else:
                    status = b"404 Not Found"

            if delay_ms:
                await asyncio.sleep(delay_ms / 1000.0)

            body = BODY if status.startswith(b"200") else status.split(b" ", 1)[1]
            response = (
                b"HTTP/1.1 " + status + b"\r\n"
                b"Content-Type: text/plain\r\n"
                b"Content-Length: " + str(len(body)).encode() + b"\r\n"
                b"Connection: keep-alive\r\n"
                b"\r\n" + body
            )
            writer.write(response)
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError, asyncio.IncompleteReadError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def main() -> None:
    server = await asyncio.start_server(handle, "0.0.0.0", PORT)
    print(f"slow-stub listening on :{PORT} (max delay {MAX_DELAY}ms)", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
