# Vendored: BMAD Method (core + bmm skills)

Source: https://github.com/bmad-code-org/BMAD-METHOD @ **v6.8.0**
Vendored: `src/` only (`bmm-skills/`, `core-skills/`, `scripts/`) + `LICENSE`.

The upstream project's website, multi-language docs, tests, and build tooling are
intentionally excluded — `.github-private` consumes only the skill definitions
(by path, vendor-neutrally; see `prompts/bmad/scrum-master.md`).

## Refresh
```bash
git clone --depth 1 --branch <tag> https://github.com/bmad-code-org/BMAD-METHOD /tmp/bmad-src
rm -rf frameworks/bmad-method/src && cp -r /tmp/bmad-src/src frameworks/bmad-method/src
cp /tmp/bmad-src/LICENSE frameworks/bmad-method/LICENSE
```
Do not hand-edit — local changes are lost on refresh.
