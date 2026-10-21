---
layout: home
mini_player: true
---

* [dev](https://github.com/dyldog)
* [musician](https://soundcloud.com/musical-dylan)
* lover of many things

<h2>Posts</h2>
<ul class="post-list">
  {% for post in site.posts %}
    <li>
      <time datetime="{{ post.date | date_to_xmlschema }}">{{ post.date | date: "%Y-%m-%d" }}</time>
      <a href="{{ post.url | relative_url }}">{{ post.title }}</a>
      {% include tag-links.html tags=post.categories %}
    </li>
  {% endfor %}
</ul>

<p><a href="{{ '/tags/' | relative_url }}">all tags →</a></p>
