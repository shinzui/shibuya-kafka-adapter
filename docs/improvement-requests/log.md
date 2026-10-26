# Bundle Update Log

## 2026-10-26
* **Update**: Link IR-1 to ExecPlan 19; block implementation on the separate migration to mori://shinzui/rdkafka-hs, replace the obsolete binding prerequisite, and specify notification lifecycle and race acceptance.

## 2026-09-30
* **Addition**: IR-1 asks the source to wait for librdkafka's queue notification instead of polling on a timer, once the fork of hw-kafka-client exposes it.
* **Bootstrap**: Establish the improvement-request bundle under the shared coordination.improvementRequests profile.
