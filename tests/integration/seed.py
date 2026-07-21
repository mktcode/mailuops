#!/usr/bin/env python3
import imaplib
import os
import ssl
from datetime import datetime, timezone
from email.message import EmailMessage
from email.policy import SMTP
from email.utils import format_datetime
from pathlib import Path

root = Path(os.environ['TEST_ROOT'])
password = (root / 'ops/secrets/source.pass').read_text().rstrip('\n')
context = ssl.create_default_context(cafile=str(root / 'pki/ca.crt'))

with imaplib.IMAP4_SSL('localhost', 993, ssl_context=context) as client:
    client.login('source@example.test', password)
    for folder in ('Sent', 'Archive/2024'):
        client.create(folder)
    for i, folder in enumerate(('INBOX', 'Sent', 'Archive/2024'), start=1):
        msg = EmailMessage()
        msg['From'] = 'source@example.test'
        msg['To'] = 'recipient@example.test'
        msg['Subject'] = f'mailuops integration {i}'
        msg['Date'] = format_datetime(datetime(2024, 1, i, 12, 0, tzinfo=timezone.utc))
        msg['Message-ID'] = f'<mailuops-integration-{i}@example.test>'
        msg.set_content(f'Integration test message {i}.\n')
        status, response = client.append(
            folder,
            r'(\Seen)' if i != 1 else None,
            imaplib.Time2Internaldate(datetime(2024, 1, i, 12, 0, tzinfo=timezone.utc)),
            msg.as_bytes(policy=SMTP),
        )
        if status != 'OK':
            raise RuntimeError(f'APPEND to {folder!r} failed: {response!r}')
    client.logout()
