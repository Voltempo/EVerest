// SPDX-License-Identifier: Apache-2.0
// Copyright Pionix GmbH and Contributors to EVerest

use nix::fcntl::{open, OFlag};
use nix::sys::stat;
use nix::unistd;
use std::io::{self};
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

/// Handle to a running EVerest manager process.
///
/// The manager is spawned as a subprocess using `{prefix}/bin/manager`. When
/// dropped, the manager process is killed if it is still running and its
/// configuration database is removed.
pub struct Manager {
    child: Arc<Mutex<Child>>,
    stopping: Arc<AtomicBool>,
    watcher: Option<thread::JoinHandle<()>>,
    db_path: PathBuf,
}

impl Manager {
    /// Start the EVerest manager as a subprocess and wait until it is ready.
    ///
    /// * `prefix` — the EVerest sysroot (passed as `--prefix`)
    /// * `config` — path to the config file (passed as `--config`)
    /// * `standalone` — module IDs that the manager should not spawn
    ///   (passed as `--standalone`). If non-empty, this function blocks until
    ///   the manager reports that all managed modules are started and it is
    ///   waiting for the standalone modules.
    /// * `mqtt_everest_prefix` — optional MQTT topic prefix override. When set,
    ///   passed as `--mqtt_everest_prefix` to the manager, allowing multiple
    ///   test instances to run in parallel without topic collisions.
    pub fn start(
        prefix: &Path,
        config: &Path,
        standalone: &[&str],
        mqtt_everest_prefix: Option<&str>,
    ) -> io::Result<Self> {
        let binary = Self::manager_binary(prefix);

        let mut cmd = Command::new(&binary);
        cmd.arg("--prefix").arg(prefix);
        cmd.arg("--config").arg(config);

        // Each instance needs its own configuration database. Without --db the manager
        // defaults to `{prefix}/everest.db`, and `prefix` is the runfiles root shared by
        // every test in a test binary, so tests running in parallel would race each other
        // applying the migration files to one database.
        let db_name = match mqtt_everest_prefix {
            Some(p) => format!("everest-{}.db", p.replace('/', "_")),
            None => format!("everest-{}.db", std::process::id()),
        };
        let db_path = std::env::temp_dir().join(db_name);
        // A leftover database would make the manager boot from the stored config slot
        // instead of seeding from the config file this instance was given.
        let _ = std::fs::remove_file(&db_path);
        cmd.arg("--db").arg(&db_path);

        if let Some(mqtt_prefix) = mqtt_everest_prefix {
            cmd.arg("--mqtt_everest_prefix").arg(mqtt_prefix);
        }

        let mut fifo = None;

        if !standalone.is_empty() {
            let fifo_name = match mqtt_everest_prefix {
                Some(p) => format!("status-{}.fifo", p.replace('/', "_")),
                None => format!("status-{}.fifo", std::process::id()),
            };
            let fifo_path = std::env::temp_dir().join(fifo_name);
            unistd::mkfifo(&fifo_path, stat::Mode::S_IRWXU)?;

            fifo = Some(open(
                &fifo_path,
                OFlag::O_RDONLY | OFlag::O_NONBLOCK,
                stat::Mode::empty(),
            )?);
            cmd.arg("--status-fifo").arg(&fifo_path);
            cmd.arg("--standalone");
            for module_id in standalone {
                cmd.arg(module_id);
            }
        }

        let child = Arc::new(Mutex::new(cmd.spawn().map_err(|e| {
            io::Error::new(
                e.kind(),
                format!("Failed to start manager at {}: {e}", binary.display()),
            )
        })?));
        let stopping = Arc::new(AtomicBool::new(false));

        let watcher = {
            let child = child.clone();
            let stopping = stopping.clone();
            Some(std::thread::spawn(move || loop {
                let status = child.lock().unwrap().try_wait().unwrap();
                match status {
                    None => thread::sleep(Duration::from_millis(100)),
                    Some(status) => {
                        if !stopping.load(Ordering::Relaxed) {
                            panic!("Manager process exited unexpectedly with status: {status}");
                        }
                        return;
                    }
                }
            }))
        };

        // Wait for the manager to signal readiness via the status fifo.
        if let Some(fd) = fifo {
            let mut buf = [0u8; 256];
            let mut accumulated = String::new();
            loop {
                match unistd::read(&fd, &mut buf) {
                    Ok(n) => {
                        accumulated.push_str(&String::from_utf8_lossy(&buf[..n]));
                        if accumulated.contains("WAITING_FOR_STANDALONE_MODULES")
                            || accumulated.contains("ALL_MODULES_STARTED")
                        {
                            break;
                        }
                    }
                    Err(nix::errno::Errno::EAGAIN) => {
                        thread::sleep(Duration::from_millis(50));
                    }
                    Err(e) => return Err(io::Error::from_raw_os_error(e as i32)),
                }

                // The watcher thread crashed - we won't see anything in our
                // fifo.
                if watcher.as_ref().unwrap().is_finished() {
                    break;
                }
            }
            let _ = unistd::close(fd);
        }

        Ok(Self {
            child,
            stopping,
            watcher,
            db_path,
        })
    }

    /// Returns the path to the manager binary for a given prefix.
    fn manager_binary(prefix: &Path) -> PathBuf {
        prefix.join("bin").join("manager")
    }
}

impl Drop for Manager {
    fn drop(&mut self) {
        self.stopping.store(true, Ordering::Relaxed);
        let _ = self.child.lock().unwrap().kill();
        let watcher = self.watcher.take().expect("always there").join();
        // Remove the database before propagating a watcher panic, so a failing test does
        // not leave one behind for the next run.
        let _ = std::fs::remove_file(&self.db_path);
        if let Err(panic) = watcher {
            std::panic::resume_unwind(panic);
        }
    }
}
