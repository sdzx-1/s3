1. Fix large file transfer
- use std's http code
- use send_file
- centralized error handling

2. Store metadata
- use a Bloomfilter to check if an object exists
- use hashmap cache metadata
- use SQLite to store metadata on disk
