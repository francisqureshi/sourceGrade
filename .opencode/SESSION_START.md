# 🚀 START HERE - Session Startup Checklist

**BEFORE DOING ANYTHING ELSE**, run this checklist every session:

## 1. Read Your Role Instructions
- [ ] `.opencode/agents/manager.md` - Your responsibilities
- [ ] `.opencode/MANAGER_INSTRUCTIONS.md` - Detailed workflow guide

## 2. Read All Agent Instructions
- [ ] `.opencode/agents/researcher.md` - Context mapping
- [ ] `.opencode/agents/architect.md` - Design and planning  
- [ ] `.opencode/agents/critic.md` - Plan review
- [ ] `.opencode/agents/backend_builder.md` - Backend work
- [ ] `.opencode/agents/frontend_builder.md` - Frontend work
- [ ] `.opencode/agents/verifier.md` - Code verification

## 3. Read Project Documentation
- [ ] `AGENTS.md` - Tech stack, conventions, build commands
- [ ] `packet/plan.md` - If one exists from previous session
- [ ] `bd ready` - Check available work

## 4. Understand the Workflow

```
User Request
    ↓
@researcher (map context → research.md)
    ↓
@architect (design plan → plan.md)
    ↓
@critic (review plan → approve/reject)
    ↓
(if approved) User approval
    ↓
@architect (create Beads)
    ↓
@backend_builder OR @frontend_builder (implement)
    ↓
@verifier (check diff against plan)
    ↓
(if approved) bd close
    ↓
git commit && bd sync && git push
```

## 5. Know the Critical Rules

✋ **NEVER do these:**
- ❌ Skip Phase 1 planning (research → architect → critic)
- ❌ Implement directly - use builders via Task tool
- ❌ Forget beads - use `bd create` when authorized
- ❌ Say "ready to commit when you are" - YOU must push
- ❌ Stop without `git push` - work isn't done until pushed

## 6. Quick Reference: Key Commands

```bash
bd ready                # Find available work
bd show <id>           # View issue details
bd create --title="..." --type=task --priority=2  # Create issue
bd update <id> --status=in_progress  # Claim work
bd close <id>          # Complete work
bd sync                # Sync beads with remote
git status             # Check what changed
git push               # MANDATORY at session end
```

## 7. Proper Git Workflow

**At session end:**
```bash
git status                    # Check changes
git add <files>              # Stage changes
bd sync                      # Sync beads
git commit -m "description"  # Commit with message
bd sync                      # Sync again if needed
git push                     # MANDATORY
git status                   # Verify "up to date with origin"
```

## 8. Example: How to Handle a User Request

User: "Add dark mode to the settings page"

**You:**
1. Summon `@researcher` → Gets context → creates `packet/research.md`
2. Summon `@architect` → Reads research → creates `packet/plan.md`
3. Summon `@critic` → Reviews plan → approves/rejects
4. **Present to user**: "Plan: [summary]. Does this look good?"
5. If approved: Summon `@architect` → `bd create` to make Beads
6. Loop: pick Bead → summon builder → summon verifier → bd close
7. Final: `git add . && bd sync && git commit && git push`

## 9. What NOT to Do (from Last Session)

❌ **What I did wrong last session:**
- Went straight to implementation without research/planning
- Didn't use beads at all
- Didn't follow Phase 1 → Phase 2 workflow
- Only committed AFTER implementation instead of planning first

✅ **What to do instead:**
- Always start with `@researcher`
- Always get `@architect` to write a plan
- Always get `@critic` to review the plan
- Get user approval BEFORE starting work
- Use `bd create` to track work
- Follow the proper Phase 1 → Phase 2 loop

## 10. Before Saying "Done"

**Mandatory checklist:**
- [ ] All Beads are closed (`bd ready` shows no work)
- [ ] `git status` shows "up to date with origin"
- [ ] Run tests/build one more time
- [ ] No uncommitted changes
- [ ] `git log --oneline -3` shows recent commits

---

**Ready?** Now go read `.opencode/agents/manager.md` and wait for the user's request!
