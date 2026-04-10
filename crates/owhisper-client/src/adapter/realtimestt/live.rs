use bytes::BytesMut;
use hypr_ws_client::client::Message;
use owhisper_interface::ListenParams;
use owhisper_interface::stream::{Alternatives, Channel, Metadata, StreamResponse};

use super::RealtimeSTTAdapter;
use crate::adapter::{RealtimeSttAdapter, set_scheme_from_host};

impl RealtimeSttAdapter for RealtimeSTTAdapter {
    fn provider_name(&self) -> &'static str {
        "realtimestt"
    }

    fn is_supported_languages(
        &self,
        languages: &[hypr_language::Language],
        model: Option<&str>,
    ) -> bool {
        RealtimeSTTAdapter::is_supported_languages_live(languages, model)
    }

    fn supports_native_multichannel(&self) -> bool {
        false
    }

    fn build_ws_url(&self, api_base: &str, _params: &ListenParams, _channels: u8) -> url::Url {
        let mut url: url::Url = api_base.parse().expect("invalid api_base URL");
        set_scheme_from_host(&mut url);
        // RealtimeSTT data channel is at the root — do NOT append /v1/listen
        url
    }

    fn build_auth_header(&self, _api_key: Option<&str>) -> Option<(&'static str, String)> {
        // RealtimeSTT has no authentication
        None
    }

    fn keep_alive_message(&self) -> Option<Message> {
        None
    }

    fn finalize_message(&self) -> Message {
        // Send a valid audio packet with zero PCM bytes to signal end-of-stream.
        // The server uses VAD to finalize utterances; this just cleanly closes the stream.
        let metadata: &[u8] = br#"{"sampleRate":16000}"#;
        let len_bytes = (metadata.len() as u32).to_le_bytes();
        let mut buf = BytesMut::with_capacity(4 + metadata.len());
        buf.extend_from_slice(&len_bytes);
        buf.extend_from_slice(metadata);
        Message::Binary(buf.freeze())
    }

    fn audio_to_message(&self, audio: bytes::Bytes) -> Message {
        // RealtimeSTT data channel expects:
        //   [4-byte LE uint32: metadata JSON byte length] [metadata JSON] [PCM bytes]
        let metadata: &[u8] = br#"{"sampleRate":16000}"#;
        let len_bytes = (metadata.len() as u32).to_le_bytes();
        let mut buf = BytesMut::with_capacity(4 + metadata.len() + audio.len());
        buf.extend_from_slice(&len_bytes);
        buf.extend_from_slice(metadata);
        buf.extend_from_slice(&audio);
        Message::Binary(buf.freeze())
    }

    fn parse_response(&self, raw: &str) -> Vec<StreamResponse> {
        let Ok(json) = serde_json::from_str::<serde_json::Value>(raw) else {
            return vec![];
        };

        let msg_type = json["type"].as_str().unwrap_or("");
        let text = json["text"].as_str().unwrap_or("");

        if msg_type != "realtime" && msg_type != "fullSentence" {
            return vec![];
        }

        if text.is_empty() {
            return vec![];
        }

        let is_final = msg_type == "fullSentence";

        vec![StreamResponse::TranscriptResponse {
            start: 0.0,
            duration: 0.0,
            is_final,
            speech_final: is_final,
            from_finalize: false,
            channel: Channel {
                alternatives: vec![Alternatives {
                    transcript: text.to_string(),
                    words: vec![],
                    confidence: 1.0,
                    languages: vec![],
                }],
            },
            metadata: Metadata::default(),
            channel_index: vec![0, 1],
        }]
    }
}
