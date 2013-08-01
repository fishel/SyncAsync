#!/usr/bin/env python

import os, sys, re, urllib, urllib2, json

def readMultiLine(f):
    contents = []
    line = f.readline()
    while line:
        content = line.strip()
        if content == '' or content.startswith('#'):
            break
        contents.append(content)
        line = f.readline()
    return '\n'.join(contents)

def readConfig(configfile):
    config = {}
    with open(configfile) as f:
        line = f.readline()
        while line:
            content = line.strip()
            if content <> '' and not content.startswith('#'):
                m = re.match('^([^=]+)=(.*)$', content)
                if m:
                    key = m.group(1).strip()
                    value = m.group(2).strip()
                    if value == '':
                        value = readMultiLine(f)
                    config[key] = value
            line = f.readline()
    return config

def confHash(line):
    conf = {}
    lines = line.split('\n')
    for aline in lines:
        m = re.match('^\s*([^\s]+)\s+(.*)$', aline)
        if m:
            key = m.group(1).strip()
            value = m.group(2).strip()
            if value <> '':
                conf[key] = value
    return conf

def ping(configfile, langpair):
    config = readConfig(configfile)
    if not 'smartmate_engine_status_url' in config:
        raise Exception, "smartmate_engine_status_url not config on this server"
    smartmate_engine_status_url = config['smartmate_engine_status_url']
    if not 'smartmate_engine_status_apikey' in config:
        raise Exception, "smartmate_engine_status_apikey not config on this server"
    smartmate_engine_status_apikey = config['smartmate_engine_status_apikey']
    langpair2engine = {}
    if 'engine list' in config:
        langpair2engine = confHash(config['engine list'])
    if not langpair in langpair2engine:
        raise Exception, "language pair [%s] is not config on this server" % langpair
    engineOID = langpair2engine[langpair]
    data = urllib.urlencode({'engineOID': engineOID, 'apikey': smartmate_engine_status_apikey}, True)
    req = urllib2.Request(smartmate_engine_status_url, data, { 'User-Agent' : 'Mozilla/4.0 (compatible; MSIE 5.5; Windows NT)' })
    response = urllib2.urlopen(req)
    the_page = response.read()
    obj = json.loads(the_page)
    if not 'result' in obj or not 'status' in obj['result']:
        raise Exception, "engine for language pair [%s] does not exist on this server" % langpair
    return obj['result']['status']

if __name__ == '__main__':
    try:
        if len(sys.argv) < 3:
            raise Exception, "Invalid argument"
        configfile = sys.argv[1]
        langpair = sys.argv[2].lower()
        print ping(configfile, langpair)
    except Exception, e:
        print "Status: %s" % str(e)
