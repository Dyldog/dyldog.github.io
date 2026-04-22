---
layout: home
---

- dev
- musician
- lover of many things
- posts
{% for post in site.posts %}
    - {{ post.date }}[{{ post.title }}]({{ post.url }})
{% endfor %}
