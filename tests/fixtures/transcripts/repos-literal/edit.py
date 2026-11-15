from pathlib import Path

HOME = Path.home()
# a literal path names its repo
Path('@tmp@/other/AGENTS.md').write_text('x')
# a path built in code or with a variable names none
(HOME / 'work' / 'plain').exists()
Path(f'{HOME}/detached/README.md')
'$G/wip/README.md'
