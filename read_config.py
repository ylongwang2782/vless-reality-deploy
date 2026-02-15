#!/usr/bin/env python3
import argparse
import os
import shlex
import sys


def strip_inline_comment(line: str) -> str:
    out = []
    in_single = False
    in_double = False
    for ch in line:
        if ch == "'" and not in_double:
            in_single = not in_single
            out.append(ch)
            continue
        if ch == '"' and not in_single:
            in_double = not in_double
            out.append(ch)
            continue
        if ch == '#' and not in_single and not in_double:
            break
        out.append(ch)
    return ''.join(out).rstrip()


def parse_value(val: str):
    if (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
        return val[1:-1]
    if val.lower() in ("true", "false"):
        return val.lower() == "true"
    try:
        return int(val)
    except ValueError:
        pass
    try:
        return float(val)
    except ValueError:
        pass
    return val


def parse_simple_yaml(path: str):
    data = {}
    stack = [(0, data)]
    with open(path, 'r', encoding='utf-8') as f:
        for raw in f:
            line = raw.rstrip('\n')
            if not line.strip():
                continue
            if line.lstrip().startswith('#'):
                continue
            line = strip_inline_comment(line)
            if not line.strip():
                continue
            indent = len(line) - len(line.lstrip(' '))
            key, sep, value = line.lstrip().partition(':')
            if not sep:
                continue
            key = key.strip()
            value = value.strip()
            while stack and indent < stack[-1][0]:
                stack.pop()
            if not stack:
                raise ValueError(f"Invalid indentation near: {raw.strip()}")
            parent = stack[-1][1]
            if value == '':
                obj = {}
                parent[key] = obj
                stack.append((indent + 2, obj))
            else:
                parent[key] = parse_value(value)
    return data


def sh(val) -> str:
    if val is None:
        val = ""
    return shlex.quote(str(val))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--file', required=True, help='config.yaml path')
    ap.add_argument('--node', default=None, help='node id')
    ap.add_argument('--merge-info', action='store_true', help='output merge info for merge_subs.sh')
    args = ap.parse_args()

    if not os.path.exists(args.file):
        print(f"[ERROR] 配置文件不存在: {args.file}", file=sys.stderr)
        return 1

    try:
        data = parse_simple_yaml(args.file)
    except Exception as e:
        print(f"[ERROR] 无法解析配置文件: {e}", file=sys.stderr)
        return 1

    nodes = data.get('nodes') or {}
    if not isinstance(nodes, dict) or not nodes:
        print("[ERROR] config.yaml 缺少 nodes 配置", file=sys.stderr)
        return 1

    # --merge-info: output primary node + all nodes for merge_subs.sh
    if args.merge_info:
        primary_id = data.get('primary') or data.get('default_node')
        if not primary_id or primary_id not in nodes:
            print("[ERROR] 缺少 primary 配置或节点不存在", file=sys.stderr)
            return 1

        primary = nodes[primary_id]
        out = [
            f"PRIMARY_ID={sh(primary_id)}",
            f"PRIMARY_SSH_HOST={sh(primary.get('ssh_host', ''))}",
            f"PRIMARY_IP={sh(primary.get('ip', ''))}",
        ]

        # ALL_NODE_IDS: "id:ssh_host:ip" space-separated (names read from config.yaml by python)
        entries = []
        for nid, n in nodes.items():
            entries.append(f"{nid}:{n.get('ssh_host', '')}:{n.get('ip', '')}")
        out.append(f"ALL_NODE_IDS={sh(' '.join(entries))}")

        print("\n".join(out))
        return 0

    node_id = args.node or data.get('default_node') or data.get('primary')
    if not node_id:
        print("[ERROR] 未指定节点，请设置 default_node/primary 或使用 --node", file=sys.stderr)
        return 1
    if node_id not in nodes:
        available = ', '.join(sorted(nodes.keys()))
        print(f"[ERROR] 节点不存在: {node_id}. 可用节点: {available}", file=sys.stderr)
        return 1

    node = nodes.get(node_id) or {}
    cf = data.get('cloudflare') or {}

    ssh_host = node.get('ssh_host')
    if not ssh_host:
        print("[ERROR] 节点缺少 ssh_host 配置", file=sys.stderr)
        return 1

    ip = node.get('ip')
    if not ip:
        print("[ERROR] 节点缺少 ip 配置", file=sys.stderr)
        return 1

    node_name = node.get('name') or node_id
    sub_port = node.get('sub_port', 8443)

    out = [
        f"NODE_ID={sh(node_id)}",
        f"NODE_NAME={sh(node_name)}",
        f"VPS_IP={sh(ip)}",
        f"SSH_HOST={sh(ssh_host)}",
        f"SUB_PORT={sh(sub_port)}",
        f"CF_API_TOKEN={sh(cf.get('api_token', ''))}",
        f"CF_DOMAIN={sh(cf.get('domain', ''))}",
        f"CF_SUBDOMAIN={sh(node.get('subdomain', ''))}",
    ]
    print("\n".join(out))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
