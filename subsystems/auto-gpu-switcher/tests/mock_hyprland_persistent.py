#!/usr/bin/env python3
"""
Mock Hyprland IPC: accepts daemon connection, forwards events from stdin.
Run with event list piped in, or interactively.
"""
import socket, sys, os, time, select

def run(sock_path):
    log_path = sock_path + ".log"

    if os.path.exists(sock_path):
        os.unlink(sock_path)

    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(sock_path)
    srv.listen(5)
    srv.settimeout(1)

    def log(msg):
        ts = time.strftime("%H:%M:%S")
        line = f"[{ts}] {msg}"
        print(line, flush=True)
        with open(log_path, "a") as f:
            f.write(line + "\n")

    log(f"Listening on {sock_path}")
    log("Waiting for daemon...")

    conn = None
    while conn is None:
        try:
            conn, _ = srv.accept()
            log("Daemon CONNECTED")
        except socket.timeout:
            continue
        except Exception as e:
            log(f"Error: {e}")
            break

    if conn is None:
        log("Failed to accept connection")
        srv.close()
        return

    # Now read events from stdin and forward to daemon
    log("Reading events from stdin (Ctrl+D to stop)...")
    conn.setblocking(False)

    # Also accept new connections (reconnect support)
    srv.settimeout(0.5)

    while True:
        # Check stdin for events
        rlist, _, _ = select.select([sys.stdin], [], [], 0.5)
        if rlist:
            line = sys.stdin.readline()
            if not line:
                log("EOF on stdin, stopping")
                break
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            try:
                conn.sendall((line + "\n").encode())
                log(f"  >> {line}")
            except (BrokenPipeError, ConnectionResetError):
                log("Daemon DISCONNECTED during send")
                break

    try:
        conn.close()
    except Exception:
        pass
    srv.close()
    try:
        os.unlink(sock_path)
    except Exception:
        pass
    log("Done")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <socket_path>")
        sys.exit(1)
    run(sys.argv[1])
