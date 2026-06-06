import re
import paramiko
from .utils import retry_operation
import logging

def parse_ping_output(output: str) -> str:
    lines = output.strip().split("\n")
    packets_line = None
    rtt_line = None

    for line in lines:
        if "packets transmitted" in line and "packet loss" in line:
            packets_line = line.strip()
        if "rtt min/avg/max/mdev" in line:
            rtt_line = line.strip()

    transmitted = received = packet_loss = None
    min_rtt = avg_rtt = max_rtt = mdev = None

    if packets_line:
        pattern_packets = re.compile(r"(\d+)\s+packets transmitted,\s+(\d+)\s+received,\s+(\d+)% packet loss")
        match = pattern_packets.search(packets_line)
        if match:
            transmitted, received, packet_loss = match.groups()

    if rtt_line:
        pattern_rtt = re.compile(r"rtt min/avg/max/mdev = ([\d\.]+)/([\d\.]+)/([\d\.]+)/([\d\.]+)\s+ms")
        match = pattern_rtt.search(rtt_line)
        if match:
            min_rtt, avg_rtt, max_rtt, mdev = match.groups()

    if transmitted and received and packet_loss and min_rtt and avg_rtt and max_rtt and mdev:
        summary = (
            f"传输包数量: {transmitted}\n"
            f"接收包数量: {received}\n"
            f"丢包率: {packet_loss}%\n"
            f"最小延迟: {min_rtt} ms\n"
            f"平均延迟: {avg_rtt} ms\n"
            f"最大延迟: {max_rtt} ms\n"
            f"标准差(mdev): {mdev} ms"
        )
        return summary
    else:
        return output

def format_nexttrace_result(raw_output: str, server_name: str, target: str, ip_type: str, trace_mode: str = "icmp") -> str:
    
    ansi_escape = re.compile(r'\x1B\[[0-?]*[ -/]*[@-~]')
    clean_output = ansi_escape.sub('', raw_output)

    
    lines = clean_output.splitlines()
    header_lines = []
    hop_lines = []
    map_url_line = None

    in_hops = False
    found_icmp_mode = False
    found_tcp_mode = False

    for line in lines:
        stripped = line.strip()
        if stripped.startswith("MapTrace URL:"):
            map_url_line = stripped
            in_hops = False
            break

        if "ICMP mode" in stripped:
            found_icmp_mode = True
            in_hops = True
            continue
            
        if "TCP mode" in stripped or "TCP SYN" in stripped:  
            found_tcp_mode = True
            in_hops = True
            continue

        if in_hops:
            hop_lines.append(stripped)
        else:
            header_lines.append(stripped)

    
    condensed_hops = []
    current_hop = ""
    hop_start_pattern = re.compile(r'^\d+\s+')
    for hl in hop_lines:
        if not hl:
            continue
        if hop_start_pattern.match(hl):
            if current_hop:
                current_hop = re.sub(r'\s+', ' ', current_hop).strip()
                condensed_hops.append(current_hop)
            current_hop = hl
        else:
            current_hop += " " + hl
    if current_hop:
        current_hop = re.sub(r'\s+', ' ', current_hop).strip()
        condensed_hops.append(current_hop)

    
    if condensed_hops:
        pattern = r'\b((?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){7}|(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){0,7})?::(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){0,7})?))\b'
        condensed_hops[0] = re.sub(pattern, 'x.x.x.x', condensed_hops[0], count=1)

    
    result = "<b>【NextTrace 路由追踪结果】</b>\n\n"
    result += f"节点: {server_name}\n"
    result += f"目标: {target}\n"
    trace_mode_text = "TCP模式" if trace_mode == "tcp" else "ICMP模式"
    result += f"执行模式: {'直接执行' if ip_type=='direct' else ip_type} ({trace_mode_text})\n\n"

    filtered_header = [h for h in header_lines if h]
    if filtered_header:
        result += "<b>头部信息</b>:\n"
        result += "<pre>" + "\n".join(filtered_header) + "</pre>\n\n"

    if not (found_icmp_mode or found_tcp_mode):
        result += f"未找到路由信息，可能 NextTrace 输出异常。\n"
        return result

    if condensed_hops:
        result += "<b>路由跳数</b>:\n"
        formatted_hops = []
        for hop in condensed_hops:
            formatted_hops.append(hop)
            if hop != condensed_hops[-1]:
                formatted_hops.append("")
        result += "<pre>" + "\n".join(formatted_hops) + "</pre>\n\n"
    else:
        result += "未捕获到路由跳数信息。\n"

    if map_url_line:
        result += f"<b>{map_url_line}</b>\n"
    else:
        result += "未发现 MapTrace URL\n"

    return result

def ping_on_server(server_info: dict, target: str, ping_count: int = 4) -> str:
    host = server_info['host']
    port = server_info['port']
    username = server_info['username']
    password = server_info['password']

    
    def ssh_connect_and_execute():
        ssh = paramiko.SSHClient()
        ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        try:
            logging.info(f"正在连接到服务器 {host}:{port}")
            ssh.connect(hostname=host, port=port, username=username, password=password, timeout=5)
            cmd = f"ping -c {ping_count} {target}"
            logging.info(f"正在执行命令: {cmd}")
            stdin, stdout, stderr = ssh.exec_command(cmd, timeout=20)
            output = stdout.read().decode('utf-8', errors='ignore')
            error = stderr.read().decode('utf-8', errors='ignore')
            ssh.close()

            if error.strip():
                return f"命令执行错误：\n{error}"
            return parse_ping_output(output)
        except Exception as e:
            ssh.close() if 'ssh' in locals() and ssh.get_transport() and ssh.get_transport().is_active() else None
            raise Exception(f"SSH或执行命令异常: {str(e)}")

    
    return retry_operation(ssh_connect_and_execute, retries=3, delay=2)

def nexttrace_on_server(server_info: dict, target: str, ip_type: str, trace_mode: str = "icmp") -> str:
    host = server_info['host']
    port = server_info['port']
    username = server_info['username']
    password = server_info['password']

    
    def ssh_connect_and_execute():
        ssh = paramiko.SSHClient()
        ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        try:
            logging.info(f"正在连接到服务器 {host}:{port}")
            ssh.connect(hostname=host, port=port, username=username, password=password, timeout=5)
            
            
            cmd_base = "nexttrace"
            
            
            if ip_type == "IPv4":
                cmd_base += " -4"
            elif ip_type == "IPv6":
                cmd_base += " -6"
            
            
            if trace_mode == "tcp":
                cmd_base += " --tcp"
            
            
            cmd = f"{cmd_base} {target}"
            
            logging.info(f"正在执行命令: {cmd}")
            stdin, stdout, stderr = ssh.exec_command(cmd, timeout=30)
            output = stdout.read().decode('utf-8', errors='ignore')
            error = stderr.read().decode('utf-8', errors='ignore')
            ssh.close()

            if error.strip():
                if "RetToken failed" in error:
                    return "路由追踪服务暂时不可用，请稍后重试。"
                return f"命令执行错误：\n{error}"
            return output
        except Exception as e:
            ssh.close() if 'ssh' in locals() and ssh.get_transport() and ssh.get_transport().is_active() else None
            raise Exception(f"SSH或执行命令异常: {str(e)}")

    
    return retry_operation(ssh_connect_and_execute, retries=3, delay=2)


def install_nexttrace_on_server(server_info: dict) -> str:
    host = server_info['host']
    port = server_info['port']
    username = server_info['username']
    password = server_info['password']

    
    def ssh_connect_and_execute():
        ssh = paramiko.SSHClient()
        ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        try:
            logging.info(f"正在连接到服务器 {host}:{port}")
            ssh.connect(hostname=host, port=port, username=username, password=password, timeout=5)
            
            
            cmd = "curl nxtrace.org/nt | bash"
            
            logging.info(f"正在执行命令: {cmd}")
            stdin, stdout, stderr = ssh.exec_command(cmd, timeout=60)  
            output = stdout.read().decode('utf-8', errors='ignore')
            error = stderr.read().decode('utf-8', errors='ignore')
            ssh.close()

            
            combined_output = output + "\n" + error
            if "一切准备就绪" in combined_output:
                return "NextTrace 安装成功！"
            elif error.strip():
                return f"命令执行错误：\n{error}"
            else:
                return f"安装输出：\n{output}\n\n未检测到'一切准备就绪'，请手动确认安装状态。"
        except Exception as e:
            ssh.close() if 'ssh' in locals() and ssh.get_transport() and ssh.get_transport().is_active() else None
            raise Exception(f"SSH或执行命令异常: {str(e)}")

    
    return retry_operation(ssh_connect_and_execute, retries=3, delay=2)
