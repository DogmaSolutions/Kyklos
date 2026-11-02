# Secrets: the agent uses them without knowing them

[← Back to the README](../README.md)

Both the `Kyklos Launcher` and the `Kyklos Bridge` (see [the components](COMPONENTS.md)) integrate with the [**Windows Credential Manager**](https://support.microsoft.com/windows/accessing-credential-manager-1b5c916a-6a16-889f-8581-fc16e8165ac0) to read and write secrets. A launch configuration names the secrets a project needs; the values
stay in the credential store. The agent reaches the outside world (the issue tracker, CI, a package registry) **through the Bridge**, which reads the secret at the moment it is needed and uses it on
the agent's behalf, so the agent never has to know a secret in advance, and never sees most of them at all.

The way the agent reaches secrets through the `Kyklos Bridge` is modelled on the [IEC 62443](https://www.isa.org/standards-and-publications/isa-standards/isa-iec-62443-series-of-standards) principles of "Zones" and "Conduits":

<p align="center">
<img src="../assets/workflow/AI-Driven_development_007.png" alt="Zones and conduits: how the agent reaches secrets through the Bridge" width="900"/>
</p>

The agent is assumed to be a valid user inside the project it works on, but some operations cross project or infrastructure boundaries that the agent's own identity cannot easily be configured for. For those, the `Kyklos Launcher` hands the agent specific, purpose-built tokens (for example to push to Git, or to read and interact with CI) instead of broad permissions that would reach into other security boundaries. This is the [Principle of Least Privilege](https://en.wikipedia.org/wiki/Principle_of_least_privilege).

The credentials are deliberately **split by purpose**:

- **The Git push credential** lets the container push branches, and nothing else (see [Git](GIT.md)). The Launcher asks GitLab what each credential can do before every launch, and **refuses to start** a project whose
  dedicated push credential could also call the API.
- **GitLab API tokens stay on the host.** A token that can call the GitLab API is never forwarded into the agent's container: the Bridge keeps it and uses it for the story, CI and messaging actions it
  performs, each one checked against the rules first. So the agent cannot use a token of its own to edit a label, close a story, merge a request or skip a check behind the workflow's back.
- **The proof signing key** (see the [Proof Table](PROOF.md)) is created on first use, stored in the Credential Manager and handed only to the Bridge process. It never reaches the container, nor the builds and
  tests the Bridge runs: they start with a clean environment.
- **Secrets on demand.** When the agent needs a secret for its own work (for example a token for a third-party service named in the project's settings), it asks the Bridge, which returns the
  current value without ever saying where it is stored; a value changed in the credential store is picked up without restarting the container.
