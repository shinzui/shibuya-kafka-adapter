---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Improvement Request

- [Wake the source on record arrival instead of polling on a timer](1-wake-the-source-on-record-arrival.md) - After the adapter migrates to rdkafka-hs, wait on queue notifications outside the consumer lock to avoid idle timer polls while preserving prompt shutdown, fatal-error detection, and delivery safety.

