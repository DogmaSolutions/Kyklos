# The three Kyklos components

[← Back to the README](../README.md)

Kyklos has three parts that work together:

- 🚀 Kyklos Launcher
- 🔀 Kyklos Bridge
- 🔌 Kyklos Plugin

Each one has a single responsibility.

<p align="center">
<img src="../assets/workflow/AI-Driven_development_009b.png" alt="The three Kyklos components: Launcher, Bridge and Plugin" width="800"/>
</p>

Specifically, the actions and roles of the three components are these:

| Component              | Where it runs                               | What it does                                                                                                                                                                                                                                                    |
|------------------------|---------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **🚀 Kyklos Launcher** | the developer's workstation (Windows first, see [Current scope](../README.md#current-scope)) | Builds and starts one isolated development container per project, with the right mounts and tools. Keeps credentials in the operating system's own credential store and hands the container only what it needs. Starts and supervises the `Kyklos Bridge`.      |
| **🔀 Kyklos Bridge**   | the host, next to the Launcher              | An [MCP](https://modelcontextprotocol.io/) Server. It's the agent's eyes and hands outside its sandbox: real builds, test runs, coverage, CI and issue-tracker actions. It holds the credentials and the business logic, issues the proof tokens, and is the one place where the rules are decided. |
| **🔌 Kyklos Plugin**   | inside the agent's session                  | Hooks and skills that steer the agent: they block a forbidden action at the moment it is attempted, remind the agent of the right tool, and send it to the `Kyklos Bridge` for anything that needs judgement or credentials.                                    |

**Why three parts:** the agent works in a sealed container and never holds a token that could act on the issue tracker or CI directly. Anything with consequences goes through the `Kyklos Bridge`,
where it is checked, logged and attributed. Logic lives once, in the `Kyklos Bridge`. The Plugin only guides the agent there and makes sure the `Kyklos Bridge` is used.

All components are available in the Kyklos marketplace, published in the [Kyklos GitHub repository](https://github.com/DogmaSolutions/Kyklos).  
Through [Docker Desktop](https://www.docker.com/products/docker-desktop/), the `Kyklos Launcher` builds a container and injects into it, from the marketplace, the `Kyklos Plugin` and the `Kyklos Bridge`.

<p align="center">
<img src="../assets/workflow/AI-Driven_development_009.png" alt="The Launcher builds the container and injects the Plugin and the Bridge" width="800"/>
</p>

See also: [how the Plugin's hooks and skills enforce the workflow](HOOKS_AND_SKILLS.md), [how secrets are handled](SECRETS.md) and [how the Bridge talks to CI](CI.md).
