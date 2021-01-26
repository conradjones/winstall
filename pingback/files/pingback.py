#!/usr/local/bin/python3

from getmac import get_mac_address
import requests
import socket

def guess_local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(('10.255.255.255', 1))
        ip = s.getsockname()[0]
    except:
        ip = '127.0.0.1'
    finally:
        s.close()
    return ip

mac = get_mac_address().replace(":","")
ip = guess_local_ip()
r = requests.get(url="http://ci-pingback.localdomain:5010/pingback?ipaddress=%s&macaddress=%s" % (ip, mac))


