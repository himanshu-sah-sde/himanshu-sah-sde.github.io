# Deploy to GitHub Pages

## 1. Create a GitHub Repository

Go to [github.com/new](https://github.com/new) and create a repository named `sunkoshi.github.io` (or any name if using a project site).

## 2. Initialize and Push


```bash
cd /path/to/personal_website
git init
git add .
git commit -m "Initial commit"
git remote add origin git@github.com:sunkoshi/sunkoshi.github.io.git
git branch -M main
git push -u origin main
```

## 3. Enable GitHub Pages

1. Go to your repo on GitHub
2. Navigate to **Settings > Pages**
3. Under **Source**, select **Deploy from a branch**
4. Set branch to `main` and folder to `/ (root)`
5. Click **Save**

## 4. Wait for Build

GitHub will automatically build your Jekyll site. You can monitor the build under the **Actions** tab. First deploy takes 1-2 minutes.

## 5. Access Your Site

Your site will be live at:

```
https://sunkoshi.github.io
```

## Custom Domain (Optional)

1. In **Settings > Pages**, enter your custom domain (e.g., `himanshu.dev`)
2. Add a `CNAME` file to your repo root containing just the domain:
   ```
   himanshu.dev
   ```
3. Configure DNS with your domain provider:
   - For apex domain: Add `A` records pointing to GitHub's IPs:
     ```
     185.199.108.153
     185.199.109.153
     185.199.110.153
     185.199.111.153
     ```
   - For subdomain (e.g., `www`): Add a `CNAME` record pointing to `sunkoshi.github.io`
4. Check **Enforce HTTPS** once DNS propagates

## Updating the Site

Any push to `main` will trigger a rebuild:

```bash
git add .
git commit -m "Update content"
git push
```

## Adding a New Blog Post

Create a file in `_posts/` with the format `YYYY-MM-DD-title.md`:

```markdown
---
layout: post
title: "Your Post Title"
date: 2025-05-14
tags: [tag1, tag2]
---

Your content here in Markdown.
```

Push to `main` and it goes live automatically.
