---
layout: home
---

- dev
- musician
- lover of many things
- posts
{% for post in site.posts %}
    - {{ post.date | date: "%B %d, %Y" }}[{{ post.title }}]({{ post.url }})
{% endfor %}
