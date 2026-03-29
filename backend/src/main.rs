use std::collections::HashMap;
use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};

use ratex_layout::{layout, to_display_list, LayoutOptions};
use ratex_parser::parser::parse;
use ratex_svg::{render_to_svg, SvgOptions};
use ratex_types::color::Color;
use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
struct Request {
    id: u64,
    #[serde(rename = "type")]
    kind: Option<String>,
    latex: Option<String>,
    font_size: Option<f64>,
    padding: Option<f64>,
    color: Option<String>,
    embed_glyphs: Option<bool>,
    font_dir: Option<String>,
}

#[derive(Debug, Serialize, Clone)]
struct SuccessResponse {
    id: u64,
    ok: bool,
    svg: String,
    width: f64,
    height: f64,
    baseline: f64,
    cached: bool,
}

#[derive(Debug, Serialize)]
struct ErrorResponse {
    id: u64,
    ok: bool,
    error: String,
}

#[derive(Debug, Serialize)]
struct PingResponse {
    id: u64,
    ok: bool,
    version: &'static str,
    protocol: &'static str,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct CacheKey {
    latex: String,
    font_size: u64,
    padding: u64,
    color: String,
    embed_glyphs: bool,
    font_dir: String,
}

fn main() {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut out = io::BufWriter::new(stdout.lock());
    let mut cache: HashMap<CacheKey, SuccessResponse> = HashMap::new();

    for line in stdin.lock().lines() {
        let line = match line {
            Ok(line) => line,
            Err(err) => {
                let _ = write_json(
                    &mut out,
                    &ErrorResponse {
                        id: 0,
                        ok: false,
                        error: format!("failed to read stdin: {err}"),
                    },
                );
                continue;
            }
        };

        if line.trim().is_empty() {
            continue;
        }

        let request = match serde_json::from_str::<Request>(&line) {
            Ok(request) => request,
            Err(err) => {
                let _ = write_json(
                    &mut out,
                    &ErrorResponse {
                        id: 0,
                        ok: false,
                        error: format!("invalid request JSON: {err}"),
                    },
                );
                continue;
            }
        };

        let result = handle_request(request, &mut cache);
        match result {
            Ok(response) => {
                let _ = write_json(&mut out, &response);
            }
            Err((id, error)) => {
                let _ = write_json(
                    &mut out,
                    &ErrorResponse {
                        id,
                        ok: false,
                        error,
                    },
                );
            }
        }
    }
}

fn handle_request(
    request: Request,
    cache: &mut HashMap<CacheKey, SuccessResponse>,
) -> Result<Response, (u64, String)> {
    let kind = request.kind.as_deref().unwrap_or("render");
    match kind {
        "ping" => Ok(Response::Ping(PingResponse {
            id: request.id,
            ok: true,
            version: env!("CARGO_PKG_VERSION"),
            protocol: "jsonl/v1",
        })),
        "render" => render_request(request, cache).map(Response::Success),
        other => Err((request.id, format!("unsupported request type: {other}"))),
    }
}

fn render_request(
    request: Request,
    cache: &mut HashMap<CacheKey, SuccessResponse>,
) -> Result<SuccessResponse, (u64, String)> {
    let latex = request
        .latex
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or((request.id, "missing non-empty `latex` field".to_string()))?;
    let font_size = request.font_size.unwrap_or(16.0);
    let padding = request.padding.unwrap_or(2.0);
    let color = request
        .color
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| {
            Color::parse(value).ok_or((request.id, format!("invalid `color` value: {value}")))
        })
        .transpose()?;
    let embed_glyphs = request.embed_glyphs.unwrap_or(true);
    let font_dir = request
        .font_dir
        .unwrap_or_else(default_font_dir)
        .trim()
        .to_string();

    let key = CacheKey {
        latex: latex.to_string(),
        font_size: font_size.to_bits(),
        padding: padding.to_bits(),
        color: color.map(|value| value.to_string()).unwrap_or_default(),
        embed_glyphs,
        font_dir: font_dir.clone(),
    };

    if let Some(cached) = cache.get(&key) {
        let mut response = cached.clone();
        response.id = request.id;
        response.cached = true;
        return Ok(response);
    }

    let nodes = parse(latex).map_err(|err| (request.id, format!("parse error: {err}")))?;
    let layout_options = if let Some(value) = color {
        LayoutOptions::default().with_color(value)
    } else {
        LayoutOptions::default()
    };
    let layout_box = layout(&nodes, &layout_options);
    let display_list = to_display_list(&layout_box);
    let svg = render_to_svg(
        &display_list,
        &SvgOptions {
            font_size,
            padding,
            stroke_width: 1.5,
            embed_glyphs,
            font_dir: font_dir.clone(),
        },
    );

    let response = SuccessResponse {
        id: request.id,
        ok: true,
        svg,
        width: display_list.width,
        height: display_list.height + display_list.depth,
        baseline: display_list.height,
        cached: false,
    };

    cache.insert(key, response.clone());
    Ok(response)
}

fn write_json<T: Serialize>(out: &mut impl Write, response: &T) -> io::Result<()> {
    serde_json::to_writer(&mut *out, response)?;
    out.write_all(b"\n")?;
    out.flush()
}

fn default_font_dir() -> String {
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let candidates = [
        cwd.join("vendor/ratex-core/fonts"),
        cwd.join("../vendor/ratex-core/fonts"),
        cwd.join("../../vendor/ratex-core/fonts"),
        PathBuf::from("vendor/ratex-core/fonts"),
        PathBuf::from("../vendor/ratex-core/fonts"),
    ];

    for candidate in candidates {
        if Path::new(&candidate).exists() {
            return candidate.to_string_lossy().into_owned();
        }
    }

    "vendor/ratex-core/fonts".to_string()
}

enum Response {
    Success(SuccessResponse),
    Ping(PingResponse),
}

impl Serialize for Response {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        match self {
            Response::Success(response) => response.serialize(serializer),
            Response::Ping(response) => response.serialize(serializer),
        }
    }
}
