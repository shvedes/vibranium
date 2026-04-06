#!/usr/bin/env bash

_log_info "Installing PWAs..."

vb-webapp-install --category AI --url 'chatgpt.com' --icon chatgpt --name ChatGPT
vb-webapp-install --category AI --url 'grok.com' --icon grok --name Grok
vb-webapp-install --category AI --url 'perplexity.ai' --icon perplexity --name Perplexity
vb-webapp-install --category AI --url 'gemini.google.com' --icon google-gemini --name Gemini
vb-webapp-install --category AI --url 'claude.ai/chats' --icon claude --name Claude
vb-webapp-install --category AI --url 'chat.deepseek.com' --icon deepseek --name DeepSeek

vb-webapp-install --category WebApp --url 'mail.google.com/mail/u/0/#inbox' --icon gmail --name Gmail
vb-webapp-install --category WebApp --url 'youtube.com' --icon youtube --name YouTube
vb-webapp-install --category WebApp --url 'reddit.com' --icon reddit --name Reddit
vb-webapp-install --category WebApp --url 'github.com' --icon github --name GitHub
vb-webapp-install --category WebApp --url 'x.com' --icon x-twitter --name X
