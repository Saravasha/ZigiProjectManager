# 🌐 ZigiProjectManager - A Fullstack Website Template Provisioner

This repository contains automation scripts to bootstrap a fullstack website project using customizable frontend/backend templates, GitHub integration, and automated VPS deployment.

---

## 🚀 Project Setup Flow

1. **Create project structure and GitHub repos** using `clone-website-template.sh`
2. **Provision and deploy the project on your VPS and manage your Application State using the Backup Manager** using `setup-vps.sh`
3. **Use local automation tool that keeps related repositories (e.g., multiple frontends/backends under the same product family) in sync.** using `multi-comitter.sh`

---

## 🧾 Prerequisite: Manual DNS Configuration

Before running the scripts, you **must configure A records** in your DNS dashboard (domain registrar or VPS provider).

### 🔐 Required DNS Records

| Subdomain                          | Type | Value (Your VPS Public IP) |
| ---------------------------------- | ---- | -------------------------- |
| `www.<your-base-domain>`           | A    | `<your VPS IP>`            |
| `www.staging.<your-base-domain>`   | A    | `<your VPS IP>`            |
| `admin.<your-base-domain>`         | A    | `<your VPS IP>`            |
| `admin-staging.<your-base-domain>` | A    | `<your VPS IP>`            |

### 🛠 Setup Instructions

1.  Log in to your DNS provider’s control panel.
2.  Add the A records above pointing to your **VPS public IP**.
3.  Wait for DNS propagation (typically a few minutes to a few hours).
4.  Verify DNS resolution:
5.  Clone the project and cd into the project directory and run ./start.sh
6.  Clone the Website Template for a new Project.
7.  Setup your VPS for your Domain Website Project.
8.  Add extra projects to the Domain Website's route path with setup-app.sh AND OR manage projects with multi-committer

```bash
   dig +short www.<your-base-domain>
   dig +short www.staging.<your-base-domain>
   dig +short admin.<your-base-domain>
   dig +short admin-staging.<your-base-domain>
```

### ✅ Requirements

```
   GitHub CLI (gh) authenticated

   A VPS with SSH access

   A domain with DNS configured
```

```
⚠️ Important Notes Before Running Scripts

   ✅ DNS must resolve before running setup-vps.sh — otherwise, SSL issuance via Certbot will fail.

   🔑 GitHub PAT is required for repository creation and must have the repo scope.

   🚫 All Git commits automatically skip CI using [skip ci] in the commit message.

   📦 Missing dependencies (like jq, gh, certbot, etc.) will be automatically installed by the script.

```

## 🔁 Multi-Repo Committer (Advanced Sync Tool)

The Multi-Repo Committer is a local automation tool that keeps related repositories (e.g., multiple frontends/backends under the same product family) in sync.

It allows you to detect, replicate, and commit changes across several repos with one command — perfect for projects where multiple codebases share common logic or UI components.

⚙️ Features

- 🔄 Automatic change detection (ignores CRLF/LF and whitespace differences)

- 🧰 Two-way safe sync via `rsync` (with dry-run preview)

- 💾 Automatic backups before every sync (`.multi-committer-backup/` folder)

- 🚫 Excludes generated/build folders (`bin/, obj/, node_modules/, dist/`, etc.)

- 🪪 GitHub authentication with stored PAT token (no manual login each time)

- 🧩 Commit, push, and PR automation from `dev` → `stage` branches

---

### 🧠 Typical Workflow

1. Open the script menu
   ```bash
   ./multi-committer.sh
   ```
2. Select your working repo
3. Select target repos (matching frontends or backends)
4. Run a dry-run sync
   ```bash
   3) Rsync dry run (preview sync)
   ```
5. Apply changes

   ```bash
   4) Rsync apply changes
   ```

6. Commit and push

   ```bash
   5) Commit all changes locally
   6) Push all commits to remote (creates PRs automatically)
   ```

### 🔒 Backups & Git Ignore

Each repo automatically maintains:

```bash
.multi-committer-backup/
```

These backups are excluded from source control by default.
If missing, the script auto-adds the exclusion line to `.gitignore`.

---

### 🔑 Authentication

The script uses the GitHub CLI with a Personal Access Token (PAT) for push/PR automation.

When first run:

- You’ll be prompted once for your token.

- It’s stored securely in `~/.multi-committer.token` (readable only by you).

- Subsequent sessions reuse the token.

---

### 🧰 Config Persistence

Your selected repos are remembered between runs via:

```bash
~/.multi-committer.cfg
```

You can safely delete this file to reset configuration.

---

### ⚠️ Notes

- Always commit your local work before applying multi-repo syncs.

- The tool intentionally avoids automation beyond PR creation to allow manual verification.

- PRs are automatically opened from `dev` → `stage`.

#### Line endings requirement:

```
All scripts must use LF (Unix) line endings.
Windows CRLF will break execution in parts of the tooling pipeline.
Run `dos2unix` on the scripts if needed.

```
