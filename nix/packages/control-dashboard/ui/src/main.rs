use control_dashboard::app::Dashboard;
use dear_app::{AddOnsConfig, AppConfig, Application, FrameContext, GpuContext, InitializedContext, PrepareFrameContext, RedrawMode, RunError, Theme};
use std::sync::Arc;

const USAGE: &str = "\
usage: control-dashboard [--server URL]

  --server URL   where control-dashboard-server is (default: http://127.0.0.1:5001)";

fn main() -> Result<(), RunError> {
    let mut server = "http://127.0.0.1:5001".to_owned();
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match (a.as_str(), args.next()) {
            ("--server", Some(s)) => server = s.trim_end_matches('/').to_owned(),
            _ => {
                eprintln!("{USAGE}");
                std::process::exit(if a == "-h" || a == "--help" { 0 } else { 2 });
            }
        }
    }
    let config = AppConfig {
        window_title: "Control".into(),
        window_size: (1400.0, 900.0),
        theme: Some(Theme::Dark),
        redraw: RedrawMode::WaitUntil { fps: 1.0 },
        addons: AddOnsConfig { with_imnodes: true, ..Default::default() },
        ..Default::default()
    };
    dear_app::run(config, Native(Dashboard::new(server)))
}

struct Native(Dashboard);

impl Application for Native {
    fn initialized(&mut self, context: &mut InitializedContext<'_>, _: &mut GpuContext<'_>) -> Result<(), RunError> {
        let wake = context.wake_handle();
        self.0.connect(Arc::new(move || _ = wake.request_redraw()));
        Ok(())
    }

    fn prepare_frame(&mut self, context: &mut PrepareFrameContext<'_>) -> Result<(), RunError> {
        self.0.textures(&mut |t| context.register_texture(t));
        Ok(())
    }

    fn frame(&mut self, context: &mut FrameContext<'_>) -> Result<(), RunError> {
        if let Some(nodes) = context.addons().imnodes() {
            self.0.frame(context.ui(), nodes);
        }
        Ok(())
    }
}
