# Push this project to your GitHub (Git Bash / terminal)

The files in this zip are the full **Kenshi Overhaul Suite** docs repo.

## 1. Create an empty repo on GitHub

1. Go to https://github.com/new  
2. Repository name: `kenshi-overhaul-suite`  
3. Public (or private)  
4. **Do not** add README, .gitignore, or license (empty repo)  
5. Create repository  

Your URL will be:

`https://github.com/gregorylogan-art/kenshi-overhaul-suite.git`

(Use your real username if different.)

## 2. Unzip and push (Git Bash)

```bash
# Go where you keep projects
cd ~/Documents   # or Desktop, or any folder you like

# Unzip (adjust path to wherever you downloaded the zip)
unzip kenshi-overhaul-suite.zip -d kenshi-overhaul-suite
cd kenshi-overhaul-suite

# New git history (zip has no .git)
git init -b main
git add .
git commit -m "Initial docs: Kenshi Overhaul Suite vision, scope, architecture, systems"

# Point at your GitHub repo
git remote add origin https://github.com/gregorylogan-art/kenshi-overhaul-suite.git

# Push (login if GitHub asks)
git push -u origin main
```

### If GitHub already created a README on the remote

```bash
git pull origin main --allow-unrelated-histories
# fix any conflict if needed, then:
git push -u origin main
```

### SSH instead of HTTPS

```bash
git remote add origin git@github.com:gregorylogan-art/kenshi-overhaul-suite.git
git push -u origin main
```

## 3. After it is up

Open: https://github.com/gregorylogan-art/kenshi-overhaul-suite  

Tell Grok the repo URL is live. With **Contents: Read and write** on the GitHub connector, Grok can commit into it on later turns. Creating repos may still require you; editing existing ones often works once permissions allow.
