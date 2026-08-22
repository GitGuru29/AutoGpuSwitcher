#!/usr/bin/env python3
"""
Hyprland IPC event injector for live GPU switching demo.
Creates a mock Hyprland .socket2.sock that the daemon connects to,
then injects activewindowv2 events to simulate window focus changes.

Usage:
    python3 inject_hyprland.py <socket_path> [event_file]

event_file: one event per line, e.g.:
    activewindowv2>>0x1a,100,steam,Steam
    activewindowv2>>0x2b,200,kitty,Terminal
"""
import socket, sys, os, time, json, signal

def run_injector(sock_path, events=None):
    if os.path.exists(sock_path):
        os.unlink(sock_path)

    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(sock_path)
    srv.listen(1)
    srv.settimeout(60)

    log_path = sock_path + ".log"
    def log(msg):
        ts = time.strftime("%H:%M:%S")
        line = f"[{ts}] {msg}"
        print(line)
        with open(log_path, "a") as f:
            f.write(line + "\n")

    log(f"Listening on {sock_path}")
    log("Waiting for daemon to connect...")

    while True:
        try:
            conn, _ = srv.accept()
        except socket.timeout:
            log("Timeout waiting for daemon. Exiting.")
            break

        log("Daemon connected!")
        try:
            if events:
                for evt in events:
                    data = (evt + "\n").encode()
                    conn.sendall(data)
                    log(f"  >> Sent: {evt}")
                    time.sleep(0.5)
            else:
                # Interactive mode: read events from stdin
                log("Interactive mode (Ctrl+D to stop)")
                for line in sys.stdin:
                    line = line.strip()
                    if not line:
                        continue
                    conn.sendall((line + "\n").encode())
                    log(f"  >> Sent: {line}")
        except (BrokenPipeError, ConnectionResetError) as e:
            log(f"Daemon disconnected: {e}")
        except KeyboardInterrupt:
            log("Interrupted")
        finally:
            conn.close()
            log("Connection closed. Waiting for reconnect...")

    srv.close()
    if os.path.exists(sock_path):
        os.unlink(sock_path)

def load_events_file(path):
    events = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                events.append(line)
    return events

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <socket_path> [event_file]")
        sys.exit(1)

    sock = sys.argv[1]
    events = None
    if len(sys.argv) >= 3:
        events = load_events_file(sys.argv[2])
        print(f"Loaded {len(events)} events from {sys.argv[2]}")

    run_injector(sock, events)
