# Build Notes

I've been building a lot of stuff with my AI assistant. Friends and colleagues ask about the setup, what's running where, how things connect. I started writing these notes to have something to point people to.

Each note describes something I actually built and use. Some are services, some are workflows, some are how I've wired a few tools together. The detail level varies. Some have code snippets. Some are more about the concept and the decisions behind it.

## What these are

I think of these as a communication tool, from me to you, or from my assistant to yours. If you point your AI assistant at one of these and say "help me build something like this," it should have enough to work with. They're also just readable on their own if you want to see what I've got running without building anything yourself.

They're not install scripts, full documentation, or specifications. They're closer to showing a friend how you wired something up in your garage. You'll build your own version for your own setup, and that's the point.

## Scope and security

Most of what's described here runs on a local network for a single user. These aren't public-facing web services. Auth is present but hasn't been through a formal security review. If you're thinking about exposing any of this to the public internet, treat these notes as a starting point and do your own hardening. For local, single-user, private network use, they work well.

## Notes

| Note | Description |
|------|-------------|
| [mac-services-api](./mac-services-api/) | REST API that exposes macOS Calendar, Reminders, and Contacts over HTTPS |
