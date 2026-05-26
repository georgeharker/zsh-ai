"""Enable ``python -m zsh_ai``."""
import sys

from .cli import main

try:
    sys.exit(main())
except BrokenPipeError:
    sys.exit(0)
