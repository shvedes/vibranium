#!/bin/bash

helpers::log::info "Installing WebApps"

vb-webapp-install \
  --category AI \
  --url 'chatgpt.com' \
  --name ChatGPT \
  --icon chatgpt

vb-webapp-install \
  --category AI \
  --url 'grok.com' \
  --name Grok \
  --icon grok

vb-webapp-install \
  --category AI \
  --url 'perplexity.ai' \
  --name Perplexity \
  --icon perplexity

vb-webapp-install \
  --category AI \
  --url 'gemini.google.com' \
  --name Gemini \
  --icon google-gemini

vb-webapp-install \
  --category AI \
  --url 'claude.ai/chats' \
  --name Claude \
  --icon claude

vb-webapp-install \
  --category AI \
  --url 'chat.deepseek.com' \
  --name DeepSeek \
  --icon deepseek

vb-webapp-install \
  --category WebApp \
  --url 'mail.google.com/mail/u/0/#inbox' \
  --name Gmail \
  --icon gmail

vb-webapp-install \
  --category WebApp \
  --url 'youtube.com' \
  --name YouTube \
  --icon youtube

vb-webapp-install \
  --category WebApp \
  --url 'reddit.com' \
  --name Reddit \
  --icon reddit

vb-webapp-install \
  --category WebApp \
  --url 'github.com' \
  --name GitHub \
  --icon github

vb-webapp-install \
  --category WebApp \
  --url 'x.com' \
  --name X \
  --icon twitter-x
