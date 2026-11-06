//! The dashboard in a browser: winit and wgpu on the page's canvas, talking to
//! the server the page came from. Dear ImGui itself is the imgui-sys-v1
//! module the page loads beside this one (see ../web/index.html).

use crate::app::Dashboard;
use dear_imgui_rs::Context;
use dear_imgui_wgpu::{FramebufferExtent, WgpuInitInfo, WgpuRenderer};
use dear_imgui_winit::{HiDpiMode, WinitPlatform};
use std::cell::RefCell;
use std::sync::Arc;
use wasm_bindgen::prelude::*;
use web_time::{Duration, Instant};
use winit::application::ApplicationHandler;
use winit::event::WindowEvent;
use winit::event_loop::{ActiveEventLoop, ControlFlow, EventLoop};
use winit::platform::web::WindowAttributesExtWebSys;
use winit::window::{Window, WindowId};

struct Gpu {
    device: wgpu::Device,
    queue: wgpu::Queue,
    surface: wgpu::Surface<'static>,
    config: wgpu::SurfaceConfiguration,
}

struct Running {
    window: Arc<Window>,
    gpu: Gpu,
    imgui: Context,
    platform: WinitPlatform,
    renderer: WgpuRenderer,
    nodes: dear_imnodes::Context,
    app: Dashboard,
    last: Instant,
}

thread_local! {
    /// GPU setup is async in a browser: it lands here when done.
    static READY: RefCell<Option<Running>> = const { RefCell::new(None) };
}

#[derive(Default)]
struct Page {
    running: Option<Running>,
}

async fn start(window: Arc<Window>, surface: wgpu::Surface<'static>, instance: wgpu::Instance) -> Result<Running, String> {
    let adapter = instance
        .request_adapter(&wgpu::RequestAdapterOptions { compatible_surface: Some(&surface), ..Default::default() })
        .await
        .map_err(|e| e.to_string())?;
    let limits = wgpu::Limits::downlevel_webgl2_defaults().using_resolution(adapter.limits()).using_alignment(adapter.limits());
    let (device, queue) = adapter
        .request_device(&wgpu::DeviceDescriptor { required_limits: limits, ..Default::default() })
        .await
        .map_err(|e| e.to_string())?;
    let caps = surface.get_capabilities(&adapter);
    let format = caps.formats.iter().copied().find(|f| f.is_srgb()).unwrap_or(caps.formats[0]);
    let size = window.inner_size();
    let config = wgpu::SurfaceConfiguration {
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
        format,
        color_space: wgpu::SurfaceColorSpace::Auto,
        width: size.width.max(1),
        height: size.height.max(1),
        present_mode: wgpu::PresentMode::Fifo,
        alpha_mode: wgpu::CompositeAlphaMode::Auto,
        view_formats: vec![],
        desired_maximum_frame_latency: 2,
    };
    surface.configure(&device, &config);

    let mut imgui = Context::create();
    imgui.set_ini_filename(None::<String>).map_err(|e| e.to_string())?;
    let mut platform = WinitPlatform::new(&mut imgui).map_err(|e| e.to_string())?;
    platform.attach_window(window.clone(), HiDpiMode::Default, &mut imgui).map_err(|e| e.to_string())?;
    let renderer = WgpuRenderer::new(WgpuInitInfo::new(device.clone(), queue.clone(), format), &mut imgui).map_err(|e| e.to_string())?;
    let nodes = dear_imnodes::Context::create(&imgui);

    let origin = web_sys::window().and_then(|w| w.location().origin().ok()).unwrap_or_default();
    let mut app = Dashboard::new(origin);
    let redraw = window.clone();
    app.connect(Arc::new(move || redraw.request_redraw()));
    Ok(Running { window, gpu: Gpu { device, queue, surface, config }, imgui, platform, renderer, nodes, app, last: Instant::now() })
}

impl Running {
    fn render(&mut self) -> Result<(), String> {
        let scale = self.window.scale_factor() as f32;
        let size = self.window.inner_size();
        if size.width == 0 || size.height == 0 {
            return Ok(());
        }
        if (size.width, size.height) != (self.gpu.config.width, self.gpu.config.height) {
            (self.gpu.config.width, self.gpu.config.height) = (size.width, size.height);
            self.gpu.surface.configure(&self.gpu.device, &self.gpu.config);
        }
        let now = Instant::now();
        let io = self.imgui.io_mut();
        io.set_display_size([size.width as f32 / scale, size.height as f32 / scale]);
        io.set_display_framebuffer_scale([scale, scale]);
        io.set_delta_time((now - self.last).as_secs_f32().max(1e-4));
        self.last = now;
        self.platform.prepare_frame(&mut self.imgui, &self.window).map_err(|e| e.to_string())?;

        let frame = match self.gpu.surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(f) | wgpu::CurrentSurfaceTexture::Suboptimal(f) => f,
            wgpu::CurrentSurfaceTexture::Lost | wgpu::CurrentSurfaceTexture::Outdated => {
                self.gpu.surface.configure(&self.gpu.device, &self.gpu.config);
                return Ok(());
            }
            _ => return Ok(()),
        };
        self.app.textures(&mut |t| self.imgui.register_texture(t));
        let token = self.imgui.try_begin_frame().map_err(|e| e.to_string())?;
        let ui = token.ui();
        self.app.frame(ui, &self.nodes);
        self.platform.prepare_render(ui, &self.window).map_err(|e| e.to_string())?;
        let pending = token.try_render(self.renderer.renderer_consumer().map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;

        let view = frame.texture.create_view(&Default::default());
        let extent = FramebufferExtent::from_texture(&frame.texture);
        let mut encoder = self.gpu.device.create_command_encoder(&Default::default());
        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: None,
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    resolve_target: None,
                    ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color { r: 0.1, g: 0.1, b: 0.12, a: 1.0 }), store: wgpu::StoreOp::Store },
                    depth_slice: None,
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });
            self.renderer.render(pending, &mut pass, extent).map_err(|e| e.to_string())?;
        }
        self.gpu.queue.submit(Some(encoder.finish()));
        self.gpu.queue.present(frame);
        Ok(())
    }
}

impl ApplicationHandler for Page {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        let canvas = web_sys::window()
            .and_then(|w| w.document())
            .and_then(|d| d.get_element_by_id("canvas"))
            .and_then(|c| c.dyn_into::<web_sys::HtmlCanvasElement>().ok());
        let window = Arc::new(event_loop.create_window(Window::default_attributes().with_title("Control").with_canvas(canvas)).expect("create window"));
        // WebGPU: Dear ImGui's wgpu renderer draws with base vertices, which WebGL lacks.
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor { backends: wgpu::Backends::BROWSER_WEBGPU, ..wgpu::InstanceDescriptor::new_without_display_handle() });
        let Ok(surface) = instance.create_surface(window.clone()) else {
            return say("This dashboard needs WebGPU, which this browser doesn't offer.");
        };
        wasm_bindgen_futures::spawn_local(async move {
            match start(window.clone(), surface, instance).await {
                Ok(r) => {
                    READY.with(|c| *c.borrow_mut() = Some(r));
                    window.request_redraw();
                }
                Err(e) => say(&format!("Couldn't start: {e}")),
            }
        });
    }

    fn window_event(&mut self, event_loop: &ActiveEventLoop, id: WindowId, event: WindowEvent) {
        if self.running.is_none() {
            self.running = READY.with(|c| c.borrow_mut().take());
        }
        let Some(r) = &mut self.running else { return };
        let full = winit::event::Event::<()>::WindowEvent { window_id: id, event: event.clone() };
        if let Err(e) = r.platform.handle_event(&mut r.imgui, &full) {
            web_sys::console::error_1(&e.to_string().into());
        }
        match event {
            WindowEvent::RedrawRequested => {
                if let Err(e) = r.render() {
                    web_sys::console::error_1(&e.into());
                }
            }
            WindowEvent::CloseRequested => event_loop.exit(),
            _ => r.window.request_redraw(),
        }
    }

    /// At least once a second, for the clocks; more on input and news.
    fn about_to_wait(&mut self, event_loop: &ActiveEventLoop) {
        if let Some(r) = &self.running {
            r.window.request_redraw();
        }
        event_loop.set_control_flow(ControlFlow::WaitUntil(Instant::now() + Duration::from_secs(1)));
    }
}

/// Instead of the dashboard, when it can't run.
fn say(text: &str) {
    if let Some(body) = web_sys::window().and_then(|w| w.document()).and_then(|d| d.body()) {
        body.set_inner_html(&format!("<p style=\"color:#e88;font:16px sans-serif;margin:2em\">{text}</p>"));
    }
}

#[wasm_bindgen(start)]
pub fn main() {
    console_error_panic_hook::set_once();
    let event_loop = EventLoop::new().expect("event loop");
    event_loop.run_app(&mut Page::default()).expect("run");
}
