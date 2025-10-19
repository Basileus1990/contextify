# contextify

`contextify` is a Bash tool that recursively scans a project directory, prints its structure, and extracts the contents of text-based files.  
It’s designed to create clean, AI-friendly context dumps for tools like ChatGPT or other LLMs.

---

## Features

- Recursively traverses directories
- Prints the full file structure in readable order
- Extracts only **textual file contents**
- Skips binaries, images, PDFs, etc.
- Includes file metadata (size, MIME type, encoding)
- Options to include hidden files, set max size, or filter extensions

---

## Usage

```bash
./contextify [options] [directory]
```

### Options
|Option|Description|
|----------|:-------------:|
|-a	| Include hidden files and directories |
|-m MAX_BYTES	| Limit max bytes per file (default: 5MB)|
|-i EXTLIST	| Include only listed extensions (e.g. py,txt,md)|
|-x EXTLIST	| Exclude listed extensions (e.g. jpg,pdf,png)|
|-h	| Show help|

### Example

```bash
./contextify -a -x "jpg,png,pdf"
```

### Example Output

```
File structure:
project/
  src/
    main.py
  README.md

------------------------------------------------

###
src/main.py
size: 1024  mime: text/x-python  encoding: utf-8  truncated: no

print("Hello, world!")
```

## Installation

```bash
git clone https://github.com/<your-username>/contextify.git
cd contextify
chmod +x contextify
```

### Optional global install:

```bash
sudo cp contextify /usr/local/bin/contextify
```

## License

MIT License © 2025
Created by Paweł Bogdanowicz
