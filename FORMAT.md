# Build Note Format

This is the structure I've been using for the build notes in this repo. It's not a standard or a spec. It's just a format I'm experimenting with to see if we can communicate how projects work between AI assistants like Claude Code and PAI.

Use as much or as little of this as makes sense for what you're describing. Not every section applies to every project, and you don't need a reference code folder if the prose covers it.

## Who they're for

Two audiences:

1. **People** who want to understand how something works and maybe build something similar.
2. **AI assistants** who've been pointed at a note by their user and asked to help build something like it. The "For AI assistants" section at the top of each note is specifically for this use case.

## Structure

Each build note is a folder with a README and optionally reference code:

```
{slug}/
  README.md              # The build note itself
  reference-code/        # Optional: sanitized source files
    README.md            # File-by-file index
    server.ts
    config.toml
    ...
```

The README is the note. Everything important is in prose. If you include reference code, it supports the prose with working examples, but the note should make sense on its own without it.

## Sections I've been using

These are the sections that have worked for the notes I've written so far. Pick what fits your project.

### Title and introduction

One paragraph: what it is, what it does, why you built it. Keep it concrete.

### For AI assistants

A short paragraph aimed at another AI assistant. This is the part that makes build notes work as agent-to-agent communication. It should cover:

- Why their user probably pointed them here
- What to ask their user before starting (3-5 specific questions about their setup, preferences, constraints)
- Where the reference code is
- That they should build for their user's setup, not copy yours

If you're not writing for the agent-to-agent use case, skip this section.

### Why I built this

The motivation. What problem you had, why existing solutions didn't fit, what you wanted instead.

### How the assistant uses it

If the project integrates with an AI assistant, explain the boundary. What does the tool do vs. what does the assistant do? How does the assistant know about it (a skill, a config, direct API calls)? This helps someone understand where the "intelligence" lives vs. where the tool just does its job.

### Architecture

An ASCII diagram showing the main components and how they connect. Keep it simple. One diagram, a few boxes, arrows showing data flow.

### What it looks like

Screenshots or diagrams showing your implementation. Not every project has a visual surface, and that's fine. Skip this for pure APIs or backend services. But if there's a UI, a dashboard, a mobile shortcut, a terminal workflow, or anything visual, a few clean screenshots help people understand what they're building toward.

For projects without a visual component, a flow diagram or architecture-style infographic can serve a similar purpose. These aren't required, but they give readers (and their AI assistants) a concrete picture of how the pieces fit together.

### What it stores/exposes/does

The data model or API surface. What goes in, what comes out, what the structure looks like. Show a sample JSON object or a route table.

### Tech stack

A table with three columns: **Component**, **Choice**, and **Why**. The "why" column is the most important part. It explains the reasoning, not just the name.

### Key decisions

This tends to be the most valuable section. List the decisions that shaped the project as questions with honest answers:

> **Why X instead of Y?**
> [Answer with trade-offs. Include when the alternative might be better.]

What makes a key decision entry useful:
- It explains the choice AND the alternative
- It's honest about downsides ("This means writing your own HTTP parsing layer")
- It tells the reader when they might want to go a different direction
- It doesn't oversell the choice that was made

Most projects have 3-7 of these.

### How it works

Subsections covering configuration, routes, key behaviors, data flow. Enough detail that someone could replicate the system, but not a line-by-line code walkthrough. The reference code handles the specifics if you include it.

### Deployment

Numbered steps to get it running. Brief and practical.

### Reference code

A pointer to the `reference-code/` folder if you have one. The notes in this repo include a disclaimer like:

> These are real files from a running system, included as reference for how one version of this looks. They're not production-hardened code meant to be deployed as-is. Use them to understand the patterns, then adapt for your own setup.

### Things to watch out for

Gotchas. Things that cost you debugging time. Surprising behaviors. Security considerations.

### What you could do differently

Alternatives someone might prefer. Different tools, different architecture, things you'd consider if starting over.

## Reference code conventions

If you include a reference-code folder:

- **Sanitize it.** No real hostnames, tokens, secrets, personal paths, or identifying details. Use generic placeholders (`your-server`, `<generated-token>`, port `4000`).
- **Keep it real.** These should be files from a working system, not toy examples. Sanitize the details, keep the logic.
- **Index it.** The `reference-code/README.md` should list each file with a one-line description of what it does.
- **Be selective.** Don't dump the entire codebase. Include the files that show how the system works. If a file is very long, include the relevant portions.

## Writing your own

If you want to write build notes for your own projects, or you're an AI assistant helping someone write one:

1. **Read the actual implementation first.** Understand the full system before you start writing.
2. **Identify the key decisions.** The choices that shaped the project and their trade-offs. This is the most valuable part of any build note.
3. **Sanitize** anything personal or infrastructure-specific if you're sharing publicly.
4. **Write the prose first.** The README is the note. Reference code supports it.
5. **Write the "For AI assistants" section** if the note is meant for other agents. Think about what another agent would need to know to help someone build something similar.
6. **Add reference code** if it helps. Real files, sanitized, with an index.
7. **Include gotchas and alternatives.** The things you learned the hard way and the paths you didn't take.

If you're an AI assistant helping your user write a build note: read through their codebase first, identify the interesting decisions, then draft the note with them. The decisions and trade-offs are the hard part. The structure is just the container.

The other notes in this repo are working examples of this format. Read through a few to get a feel for the structure and level of detail before writing your own.

The format here is just what's worked for me so far. Adapt it however makes sense for your projects.
