#!/usr/bin/env python3
import imaplib
import os
import re
import ssl
from pathlib import Path

root = Path(os.environ['TEST_ROOT'])
password = (root / 'ops/secrets/target.pass').read_text().rstrip('\n')
context = ssl.create_default_context(cafile=str(root / 'pki/ca.crt'))
expected = {f'<mailuops-integration-{i}@example.test>' for i in range(1, 4)}
found = set()
folders_seen = set()

with imaplib.IMAP4_SSL('localhost', 993, ssl_context=context) as client:
    client.login('target@example.test', password)
    status, folders = client.list()
    if status != 'OK':
        raise RuntimeError(f'LIST failed: {folders!r}')
    for raw in folders or []:
        text = raw.decode(errors='replace')
        match = re.search(r' "?([^"/]+(?:/[^"/]+)*)"?$', text)
        if match:
            folders_seen.add(match.group(1).strip('"'))
    for required in ('Sent', 'Archive'):
        if required not in '\n'.join(x.decode(errors='replace') for x in folders or []):
            raise RuntimeError(f'missing folder {required!r}; LIST returned {folders!r}')
    for folder in ('INBOX', 'Sent', 'Archive'):
        status, _ = client.select(f'"{folder}"', readonly=True)
        if status != 'OK':
            raise RuntimeError(f'cannot select {folder!r}')
        status, data = client.search(None, 'ALL')
        if status != 'OK':
            raise RuntimeError(f'SEARCH failed in {folder!r}')
        for num in data[0].split():
            status, response = client.fetch(num, '(BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)] FLAGS INTERNALDATE)')
            if status != 'OK':
                raise RuntimeError(f'FETCH failed for {num!r} in {folder!r}')
            for item in response:
                if not isinstance(item, tuple):
                    continue
                header = item[1].decode(errors='replace')
                for line in header.splitlines():
                    if line.lower().startswith('message-id:'):
                        found.add(line.split(':', 1)[1].strip())
    client.logout()

missing = expected - found
extra_count = len(found - expected)
if missing:
    raise RuntimeError(f'missing migrated messages: {sorted(missing)!r}; found={sorted(found)!r}')
if extra_count:
    raise RuntimeError(f'unexpected extra message IDs: {sorted(found - expected)!r}')
print('Destination mailbox verification passed.')
