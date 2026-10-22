# Pasteruperer

A Mac app for writing, editing, previewing and deleting posts on this blog.

```sh
make run       # generate the Xcode project, build, and open the app
make install   # …or copy it into /Applications
make test
```

The project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`
(`make project` or `xcodegen generate`), so `Pasteruperer.xcodeproj` isn't checked in.

## Using it

- **Sidebar**: local drafts, `_drafts/` files, and published posts. Clicking a post shows it; it only
  becomes a draft once you change something. Right-click a post to delete it.
- **Writing**: Markdown text blocks with a Format menu and toolbar (⌘B, ⌘I, ⌘K, headings, lists,
  quotes). Pasting a link over selected text makes a Markdown link. Pasting or dropping images and audio
  inserts them where the cursor is; images can also come from Photos.
- **Preview** (⌥⌘P): runs the blog's own `bundle exec jekyll serve` on an APFS clone of the site in
  `~/Library/Caches/Pasteruperer/Preview`, so the real checkout is never touched. It updates as you
  type. Needs `bundle install` to have been run in the blog folder.
- **Post** (⌘↩): publish to `_posts/`, or save to `_drafts/` (committed, not on the site).

## What it writes

The same files a hand-written post uses:

| Thing | File |
| --- | --- |
| Post | `_posts/<yyyy-mm-dd>-<slug>.md` (or `_drafts/<slug>.md`) with `layout`, `title`, `date`, `categories` front matter. Other front matter is kept as it was |
| Image | `images/<slug>/<name>.jpeg` (cropped, scaled, metadata stripped; PNGs stay PNG), referenced as `![alt]({{ site.baseurl }}/images/…)`, plus `{: style="width: N%"}` when narrower than the column. Images already in the repo that aren't cropped or shrunk are linked where they are |
| Audio | `art/music/<title>.m4a` (other formats are converted), listed in `_data/<slug>.yml` and rendered with `{% include music-player.html … %}`. Drafts put audio in `art/drafts/` so the home page's random player doesn't find it; publishing moves it. Tracks already in the repo are linked, not copied |

Committing only touches those files (anything else in the working tree is left alone), then runs
`git pull --rebase --autostash` and `git push`. Editing a post updates it in place, renames it if
the slug or date changed, and removes playlists it no longer uses. Deleting removes the post, its
playlists, and optionally images and audio nothing else refers to. If anything fails before the
commit, every change is undone. If only the push fails, the commit stays and you can retry.

Post URLs in `_data/*.yml` use the site's `timezone` from `_config.yml`, or UTC (what GitHub Pages
uses) when it isn't set.

Drafts autosave to `~/Library/Application Support/Pasteruperer/Drafts/`, and pasted or Photos images
are kept in `…/Pasteruperer/Media/` until no draft uses them.

## Design

The look is futuristic graffiti and paste-ups: a concrete wall, the post as a torn newsprint poster,
tape, sticker buttons, and neon pink / cyan / acid / violet, set in [Bungee](https://fonts.google.com/specimen/Bungee)
and [Permanent Marker](https://fonts.google.com/specimen/Permanent+Marker) (licences in
`Pasteruperer/Fonts`). Shared styles are in `Views/Theme.swift`.

The icon and textures are drawn in code: `Design/icon.py` (SVG, three concepts; C is the app icon)
and `Design/textures.py`. `Design/build-assets.sh` renders them with headless Chrome into
`Assets.xcassets`.
