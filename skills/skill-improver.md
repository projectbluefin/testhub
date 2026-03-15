# Skill Improver

Quality standard for all files in `skills/`. Apply this checklist when creating or
updating any skill file. Adapted from
[trailofbits/skill-improver](https://skills.sh/trailofbits/skills/skill-improver).

## When to Use
- Creating a new skill file
- After a session that produced lessons learned
- When a skill file exceeds 500 lines
- When a skill file has missing or incorrect information

## When NOT to Use
- Editing a single known fact (just edit the file directly)
- Reviewing non-skill files (AGENTS.md, Justfile, etc.)

## Quality Checklist

### Critical (fix immediately)
- [ ] No broken file references (links to files that don't exist)
- [ ] No factually incorrect information

### Major (must fix)
- [ ] Has "When to Use" section
- [ ] Has "When NOT to Use" section
- [ ] Uses imperative voice, not second person ("Read the manifest" not "You should read")
- [ ] ≤500 lines — extract reference material to `skills/references/` if over

### Minor (evaluate before fixing)
- [ ] Consistent heading hierarchy
- [ ] Examples are up to date

## Fix Cycle
1. Read the skill file
2. Apply checklist — note critical/major issues
3. Fix all critical and major issues
4. For minor issues: fix only if clearly beneficial
5. Commit with message: `docs(skills): update <skill> — lessons learned / quality improvements`
