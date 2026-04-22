---
layout: home
---

- [dev](https://github.com/dyldog)
- [musician](https://soundcloud.com/musical-dylan)
- lover of many things 
- posts 
    {% for post in site.posts %}- {{ post.date | date: "%Y-%m-%d" }} [{{ post.title }}]({{ post.url }}) {% endfor %}

