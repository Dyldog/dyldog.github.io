---
layout: page
title: Posts by tag
permalink: /tags/
---

<div class="tag-archive">
  {% assign sorted_categories = site.categories | sort %}
  {% for category in sorted_categories %}
    {% assign tag = category[0] %}
    <section id="{{ tag | slugify }}">
      <h2>{{ tag }}</h2>
      <ul class="post-list">
        {% for post in category[1] %}
          <li>
            <time datetime="{{ post.date | date_to_xmlschema }}">{{ post.date | date: "%Y-%m-%d" }}</time>
            <a href="{{ post.url | relative_url }}">{{ post.title }}</a>
          </li>
        {% endfor %}
      </ul>
    </section>
  {% endfor %}
</div>
