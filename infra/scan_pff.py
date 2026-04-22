#!/usr/bin/env python3
"""Metadata + ownership scanner for PST/OST files via pypff.

Reports folder tree, message counts, date ranges, AND (for Q0 account attribution):
- Store display name
- Top sender-email DOMAINS aggregated (inbound correspondents)
- Top recipient-email DOMAINS aggregated (outbound correspondents)
- Top full sender addresses observed in "Sent"-style folders (identifies mailbox owner)
- Message-ID set (written to a sidecar file) for per-file overlap comparison

Privacy discipline:
- Never prints message subjects, bodies, or individual non-Sent sender/recipient addresses.
- Inbound/outbound correspondent addresses are bucketed to domain only.
- Sent-folder sender addresses ARE printed in full because they identify the mailbox owner itself.
- Message-IDs (if requested) are written to a sidecar file, not the report, for overlap math only.
"""
import sys
import os
import re
import pypff
from collections import Counter


SENT_FOLDER_MARKERS = ("gesendete", "sent", "gesendet", "outbox-sent", "postausgang")


def fmt_date(d):
    if d is None:
        return "-"
    try:
        return d.strftime("%Y-%m-%d")
    except Exception:
        return str(d)[:10]


def extract_domain(addr):
    if not addr:
        return None
    addr = addr.strip().strip("<>").lower()
    if "@" in addr:
        return addr.rsplit("@", 1)[1].strip()
    if addr.startswith("/o=") or addr.startswith("/cn="):
        return "(internal-exchange-x500)"
    return "(no-at-sign)"


def is_sent_folder(name):
    if not name:
        return False
    low = name.lower()
    return any(marker in low for marker in SENT_FOLDER_MARKERS)


def header_line_value(headers, name):
    if not headers:
        return None
    pattern = re.compile(r"^" + re.escape(name) + r":\s*(.+)$", re.MULTILINE | re.IGNORECASE)
    match = pattern.search(headers)
    return match.group(1).strip() if match else None


def get_sender_address_from_message(msg):
    for getter in ("get_sender_email_address", "sender_email_address"):
        if hasattr(msg, getter):
            try:
                val = getattr(msg, getter)
                if callable(val):
                    val = val()
                if val:
                    return val
            except Exception:
                pass
    try:
        headers = msg.get_transport_headers() if hasattr(msg, "get_transport_headers") else None
    except Exception:
        headers = None
    if headers:
        raw = header_line_value(headers, "From")
        if raw:
            m = re.search(r"[\w.+-]+@[\w-]+\.[\w.-]+", raw)
            if m:
                return m.group(0)
    return None


def get_recipient_domains(msg):
    out = []
    try:
        n = msg.number_of_recipients or 0
    except Exception:
        n = 0
    for i in range(n):
        try:
            r = msg.get_recipient(i)
            addr = None
            for attr in ("get_email_address", "email_address"):
                if hasattr(r, attr):
                    v = getattr(r, attr)
                    addr = v() if callable(v) else v
                    if addr:
                        break
            d = extract_domain(addr) if addr else None
            if d:
                out.append(d)
        except Exception:
            continue
    if not out:
        try:
            headers = msg.get_transport_headers() if hasattr(msg, "get_transport_headers") else None
            if headers:
                for hname in ("To", "Cc"):
                    raw = header_line_value(headers, hname)
                    if raw:
                        for m in re.finditer(r"[\w.+-]+@[\w-]+\.[\w.-]+", raw):
                            d = extract_domain(m.group(0))
                            if d:
                                out.append(d)
        except Exception:
            pass
    return out


def get_message_date(msg):
    for getter in ("get_delivery_time", "get_client_submit_time", "get_creation_time"):
        if hasattr(msg, getter):
            try:
                d = getattr(msg, getter)()
                if d:
                    return d
            except Exception:
                pass
    return None


def get_message_id(msg):
    try:
        headers = msg.get_transport_headers() if hasattr(msg, "get_transport_headers") else None
    except Exception:
        return None
    if not headers:
        return None
    v = header_line_value(headers, "Message-ID")
    if v:
        return v.strip().strip("<>")
    return None


def walk(folder, depth, stats, in_sent=False):
    name = folder.name or "(root)"
    sent_here = in_sent or is_sent_folder(name)
    n = 0
    try:
        n = folder.number_of_sub_messages or 0
    except Exception:
        pass
    earliest, latest = None, None
    for i in range(n):
        try:
            m = folder.get_sub_message(i)
            d = get_message_date(m)
            if d:
                if not earliest or d < earliest:
                    earliest = d
                if not latest or d > latest:
                    latest = d
            sender = get_sender_address_from_message(m)
            if sender:
                dom = extract_domain(sender)
                if dom:
                    stats["sender_domains"][dom] += 1
                if sent_here and "@" in sender:
                    stats["sent_sender_addresses"][sender.lower().strip()] += 1
            for rdom in get_recipient_domains(m):
                stats["recipient_domains"][rdom] += 1
            mid = get_message_id(m)
            if mid:
                stats["message_ids"].add(mid)
        except Exception:
            continue
    stats["folders"].append((depth, name, n, earliest, latest, sent_here))
    stats["total_msgs"] += n
    if earliest and (not stats["earliest"] or earliest < stats["earliest"]):
        stats["earliest"] = earliest
    if latest and (not stats["latest"] or latest > stats["latest"]):
        stats["latest"] = latest
    sub = 0
    try:
        sub = folder.number_of_sub_folders or 0
    except Exception:
        pass
    for j in range(sub):
        try:
            walk(folder.get_sub_folder(j), depth + 1, stats, in_sent=sent_here)
        except Exception:
            continue


def scan(path, emit_msgids_to=None):
    print("=" * 78)
    print("file:", path)
    f = pypff.file()
    f.open(path)

    ms = f.get_message_store()
    for attr in ("get_display_name", "get_identifier"):
        if hasattr(ms, attr):
            try:
                v = getattr(ms, attr)()
                print(f"store.{attr}(): {v!r}")
            except Exception as e:
                print(f"store.{attr}(): <error: {e}>")
    root = f.get_root_folder()
    if hasattr(root, "name"):
        try:
            print(f"root.name: {root.name!r}")
        except Exception:
            pass

    stats = {
        "total_msgs": 0,
        "earliest": None,
        "latest": None,
        "folders": [],
        "sender_domains": Counter(),
        "recipient_domains": Counter(),
        "sent_sender_addresses": Counter(),
        "message_ids": set(),
    }
    walk(root, 0, stats)

    print(f"total messages: {stats['total_msgs']}")
    print(f"earliest message: {fmt_date(stats['earliest'])}")
    print(f"latest message:   {fmt_date(stats['latest'])}")
    print(f"message-ids collected: {len(stats['message_ids'])}")
    print("--- top 10 sender domains (inbound correspondents) ---")
    for dom, count in stats["sender_domains"].most_common(10):
        print(f"  {count:>6}  {dom}")
    print("--- top 10 recipient domains (outbound correspondents) ---")
    for dom, count in stats["recipient_domains"].most_common(10):
        print(f"  {count:>6}  {dom}")
    print("--- top 5 full sender addresses observed in Sent-type folders (mailbox owner) ---")
    for addr, count in stats["sent_sender_addresses"].most_common(5):
        print(f"  {count:>6}  {addr}")
    print("--- folder tree (depth / name / msgs / earliest / latest / sent?) ---")
    for depth, name, n, e, l, sent in stats["folders"]:
        if n == 0 and not sent:
            continue
        indent = "  " * depth
        marker = "S" if sent else " "
        print(f"{marker} {indent}{name[:50]:<50} {n:>7}  {fmt_date(e):<11}  {fmt_date(l):<11}")

    if emit_msgids_to:
        with open(emit_msgids_to, "w", encoding="utf-8") as fh:
            for mid in sorted(stats["message_ids"]):
                fh.write(mid + "\n")
        print(f"message-ids written to: {emit_msgids_to}")

    f.close()


def main():
    argv = sys.argv[1:]
    if "--emit-msgids" in argv:
        idx = argv.index("--emit-msgids")
        out_dir = argv[idx + 1]
        paths = argv[:idx] + argv[idx + 2:]
        for p in paths:
            sidecar = os.path.join(out_dir, os.path.basename(p).replace(" ", "_") + ".mids")
            try:
                scan(p, emit_msgids_to=sidecar)
            except Exception as e:
                print(f"ERROR scanning {p}: {e}")
            print()
    else:
        for p in argv:
            try:
                scan(p)
            except Exception as e:
                print(f"ERROR scanning {p}: {e}")
            print()


if __name__ == "__main__":
    main()
