#!/usr/bin/env bash

_log_info "Installing PWAs..."

vb-webapp-install --category AI --url 'chatgpt.com' --name ChatGPT --icon chatgpt
vb-webapp-install --category AI --url 'grok.com' --name Grok --icon grok
vb-webapp-install --category AI --url 'perplexity.ai' --name Perplexity --icon perplexity
vb-webapp-install --category AI --url 'gemini.google.com' --name Gemini --icon google-gemini
vb-webapp-install --category AI --url 'claude.ai/chats' --name Claude --icon claude
vb-webapp-install --category AI --url 'chat.deepseek.com' --name DeepSeek --icon deepseek

vb-webapp-install --category WebApp --url 'mail.google.com/mail/u/0/#inbox' --icon gmail --name Gmail
vb-webapp-install --category WebApp --url 'youtube.com' --icon youtube --name YouTube
vb-webapp-install --category WebApp --url 'reddit.com' --icon reddit --name Reddit
vb-webapp-install --category WebApp --url 'github.com' --icon github --name GitHub
vb-webapp-install --category WebApp --url 'x.com' --icon twitter-x --name X
