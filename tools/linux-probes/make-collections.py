#!/usr/bin/env python3
"""Kleine unabhängige Sammlung mit zwei Dokumenten und einem PNG je Format."""
import base64, email.policy, hashlib, json, mailbox, pathlib, sys, struct, zlib
from email.message import EmailMessage
root = pathlib.Path(sys.argv[1]); root.mkdir(parents=True, exist_ok=False)
def chunk(kind, payload):
    return struct.pack('>I',len(payload))+kind+payload+struct.pack('>I',zlib.crc32(kind+payload)&0xffffffff)
png = b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',1,1,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(b'\x00\xff\x00\x00\xff'))+chunk(b'IEND',b'')
box = mailbox.mbox(root / 'mail.mbox')
for index in range(2):
    m = EmailMessage(policy=email.policy.default)
    m['From'] = 'sender@example.invalid'; m['To'] = 'reader@example.invalid'
    m['Subject'] = f'Message {index+1}'; m['Date'] = 'Sat, 01 Jan 2022 00:00:00 +0000'
    m.set_content(f'Message {index+1} alpha ä 😀\n')
    if index == 0: m.add_attachment(png, maintype='image', subtype='png', filename='pixel.png')
    box.add(m)
box.close()
notes=[]
for index in range(2):
    image = f'<en-media type="image/png" hash="{hashlib.md5(png).hexdigest()}"/>' if index == 0 else ''
    resource = f'<resource><data encoding="base64">{base64.b64encode(png).decode()}</data><mime>image/png</mime><resource-attributes><file-name>pixel.png</file-name></resource-attributes></resource>' if index == 0 else ''
    notes.append(f'<note><title>Note {index+1}</title><content><![CDATA[<?xml version="1.0"?><!DOCTYPE en-note SYSTEM "http://xml.evernote.com/pub/enml2.dtd"><en-note>Note {index+1} alpha ä 😀{image}</en-note>]]></content>{resource}</note>')
(root/'notes.enex').write_text('<?xml version="1.0"?><en-export>'+''.join(notes)+'</en-export>')
for stem in ('mail','notes'):
    target=root/stem; target.mkdir(); (target/'index.md').write_text('Unverändert\n')
(root/'source-hashes.json').write_text(json.dumps({n:hashlib.sha256((root/n).read_bytes()).hexdigest() for n in ('mail.mbox','notes.enex')}, indent=2)+'\n')
(root/'asset.sha256').write_text(hashlib.sha256(png).hexdigest()+'\n')
