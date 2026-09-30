let UpstreamIssues =
      https://raw.githubusercontent.com/shinzui/mori-schema/3522f4a51181d73c9c90fc27a7c0838bd29ae95f/extensions/upstream-issues/package.dhall
        sha256:50f8b061a1bd999aac83e3f0ed69cd5a829d2bcf101f556a733f52ed9671e064

in  UpstreamIssues.UpstreamIssuesCatalog::{
    , entries =
      [ UpstreamIssues.UpstreamIssue::{
        , key = "hw-kafka-client-no-queue-event-binding"
        , dependency = "hw-kafka-client"
        , summary =
            "No binding exists for librdkafka's rd_kafka_queue_io_event_enable, and the queue the consumer reads from is internal to hw-kafka-client, so a source that must not block inside the client while holding the adapter's consumer lock can only poll with a zero timeout and sleep between attempts (docs/bug-reports BUG-7, docs/plans/18)"
        , status = UpstreamIssues.IssueStatus.Active
        , revisitTrigger = Some
            "When mori://shinzui/hw-kafka-client/okf/improvement-requests/concepts/IR-1 is completed and kafka-effectful exposes the operation; then implement docs/improvement-requests IR-1 here. Not filed upstream: haskell-works/hw-kafka-client last pushed in October 2025 and has not answered its issue #213, so the maintained fork carries it. Plan 18 changes this entry to Workaround with workaroundPath shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs."
        , upstreamUrl = Some "https://github.com/shinzui/hw-kafka-client"
        , tags = [ "kafka", "consumer", "latency", "idle-cpu", "no-upstream-ticket" ]
        }
      ]
    }
