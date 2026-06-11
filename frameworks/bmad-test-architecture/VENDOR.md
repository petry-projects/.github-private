# Vendored: BMad Test Architect (module "tea", agent "Murat")

Source: https://github.com/bmad-code-org/bmad-method-test-architecture-enterprise @ **v1.19.0**
Vendored: `src/` only (`agents/bmad-tea`, `workflows/testarch`) + `LICENSE`.

The official BMAD Test Architect expansion module. Consumed by path (see
`prompts/bmad/scrum-master.md`); the planner uses its test-design guidance to
sharpen story acceptance criteria.

## Refresh
```bash
git clone --depth 1 --branch <tag> https://github.com/bmad-code-org/bmad-method-test-architecture-enterprise /tmp/tea-src
rm -rf frameworks/bmad-test-architecture/src && cp -r /tmp/tea-src/src frameworks/bmad-test-architecture/src
cp /tmp/tea-src/LICENSE frameworks/bmad-test-architecture/LICENSE
```
Do not hand-edit — local changes are lost on refresh.
