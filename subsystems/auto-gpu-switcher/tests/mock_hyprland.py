#!/usr/bin/env python3
"""Mock Hyprland IPC server for sandbox testing.
Listens on a Unix socket and sends activewindowv2 events."""
import socket, sys, os, time, threading

def run_server(sock_path, log_path, events):
    if os.path.exists(sock_path):
        os.unlink(sock_path)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(sock_path)
    srv.listen(1)
    srv.settimeout(30)
    print(f"[mock-hypr] listening on {sock_path}")

    while True:
        try:
            conn, _ = srv.accept()
        except socket.timeout:
            break
        print(f"[mock-hypr] daemon connected")
        with open(log_path, "a") as log:
            log.write("connected\n")
        try:
            for evt in events:
                data = (evt + "\n").encode()
                conn.sendall(data)
                print(f"[mock-hypr] sent: {evt}")
                with open(log_path, "a") as log:
                    log.write(f"sent: {evt}\n")
                time.sleep(0.3)
            time.sleep(5)
        except (BrokenPipeError, ConnectionResetError):
            print("[mock-hypr] daemon disconnected")
        finally:
            conn.close()

if __name__ == "__main__":
    sock = sys.argv[1]
    log = sys.argv[2]
    events = sys.argv[3:]
    run_server(sock, log, events)
