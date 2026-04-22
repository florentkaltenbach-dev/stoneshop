#!/usr/bin/env python3
"""Quick mailbox inventory via IMAP STATUS (doesn't change selected state)."""
import imaplib
import re
import ssl
import sys


def main():
    password = sys.argv[1] if len(sys.argv) > 1 else ""
    imap = imaplib.IMAP4("127.0.0.1", 143)
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    imap.starttls(ssl_context=ctx)
    imap.login("info@fraefel.de", password)
    try:
        imap._simple_command("ENABLE", "UTF8=ACCEPT")
    except Exception:
        pass

    typ, data = imap.list()
    folders = []
    for line in (data or []):
        s = line.decode("utf-8", errors="replace") if isinstance(line, bytes) else line
        m = re.match(r"\((.*?)\) \"(.*?)\" (.+)", s)
        if m:
            folders.append(m.group(3).strip().strip('"'))

    total = 0
    non_empty = []
    for name in folders:
        quoted = '"' + name + '"'
        try:
            typ, data = imap._simple_command("STATUS", quoted, "(MESSAGES)")
            if typ != "OK":
                continue
            # The response comes via untagged STATUS response
            # Fetch from imap.response('STATUS')
            typ2, resp = imap.response("STATUS")
            if resp:
                for r_line in resp:
                    rs = r_line.decode("utf-8", errors="replace") if isinstance(r_line, bytes) else r_line
                    m2 = re.search(r"MESSAGES\s+(\d+)", rs)
                    if m2:
                        cnt = int(m2.group(1))
                        total += cnt
                        if cnt:
                            non_empty.append((name, cnt))
                        break
        except Exception:
            continue

    print(f"total folders: {len(folders)}")
    print(f"total messages: {total}")
    print("non-empty folders:")
    for n, c in sorted(non_empty, key=lambda x: -x[1]):
        print(f"  {c:5d}  {n}")

    imap.logout()


if __name__ == "__main__":
    main()
