#!/usr/bin/env python

import re, sys

SPACE_APOSTROPHE = re.compile(r"([a-zA-Z]+)\s+('[a-zA-Z]+)", flags = re.U | re.I)

HEADER_FOR_N = set(['m', 'zo', 'z'])

def space_apostrophe_callback(m):
    global HEADER_FOR_N
    pre = m.group(1)
    post = m.group(2)
    prelc = pre.lower()
    postlc = post.lower()
    content = m.group(0)
    if (postlc == "'n" and not prelc in HEADER_FOR_N) or postlc == "'t":
        return content
    else:
        return pre + post

rawline = " "
while rawline <> "":
    rawline = sys.stdin.readline()
    if rawline == "":
        break
    line = rawline.strip().decode('utf8')
    line = SPACE_APOSTROPHE.sub(space_apostrophe_callback, line)
    print >> sys.stdout, line.strip().encode('utf8')
    sys.stdout.flush()
