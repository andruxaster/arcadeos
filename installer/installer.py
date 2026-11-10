#!/usr/bin/env python3
"""ArcadeOS installer UI: black screen, one big INSTALL button.

Runs as the only X client (started by xinit from arcadeos-installer.service).
All real work is done by install.sh; this file only draws and parses @@ lines.
"""
import os
import queue
import subprocess
import threading
import tkinter as tk

VERSION = "@ARCADEOS_VERSION@"
HERE = os.path.dirname(os.path.abspath(__file__))
BACKEND = os.path.join(HERE, "install.sh")

BG, FG, DIM, ACC, ERR = "#000000", "#f0f0f0", "#707070", "#ffc828", "#ff4040"
FONT = "DejaVu Sans"


def human(nbytes):
    n = float(nbytes)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1000:
            return f"{n:.0f} {unit}"
        n /= 1000
    return f"{n:.0f} PB"


class Installer:
    def __init__(self, root):
        self.root = root
        self.q = queue.Queue()
        self.proc = None
        self.result = {}
        root.configure(bg=BG, cursor="arrow")
        w, h = root.winfo_screenwidth(), root.winfo_screenheight()
        root.geometry(f"{w}x{h}+0+0")
        root.overrideredirect(True)
        self.s = max(1.0, h / 1080)          # UI scale for big screens
        self.frame = None
        self.root.after(100, self.poll)
        self.screen_home()

    # ---------- helpers ----------
    def f(self, size, bold=False):
        return (FONT, int(size * self.s), "bold" if bold else "normal")

    def clear(self):
        if self.frame:
            self.frame.destroy()
        self.frame = tk.Frame(self.root, bg=BG)
        self.frame.place(relx=0.5, rely=0.5, anchor="center")
        return self.frame

    def label(self, parent, text, size=18, color=FG, bold=False, **kw):
        lb = tk.Label(parent, text=text, bg=BG, fg=color, font=self.f(size, bold), **kw)
        lb.pack(pady=int(6 * self.s))
        return lb

    def button(self, parent, text, cmd, primary=True, size=26):
        b = tk.Button(parent, text=text, command=cmd, font=self.f(size, True),
                      bg=ACC if primary else BG, fg=BG if primary else FG,
                      activebackground=FG, activeforeground=BG,
                      relief="flat", bd=0, highlightthickness=2,
                      highlightbackground=ACC, padx=int(40 * self.s), pady=int(12 * self.s))
        b.pack(pady=int(10 * self.s))
        return b

    def backend(self, *args):
        out = subprocess.run([BACKEND, *args], capture_output=True, text=True)
        return out.stdout.splitlines()

    # ---------- screens ----------
    def screen_home(self):
        fr = self.clear()
        self.label(fr, "ARCADE", 110, ACC, True)
        self.label(fr, "O P E R A T I N G   S Y S T E M", 20, FG)
        self.label(fr, f"version {VERSION}", 14, DIM)
        tk.Frame(fr, bg=BG, height=int(60 * self.s)).pack()
        self.disks = []
        for line in self.backend("--list-disks"):
            if line.startswith("@@DISK "):
                _, dev, size, existing, model = line.split(" ", 4)
                self.disks.append((dev, int(size), existing == "1", model))
        b = self.button(fr, "INSTALL", lambda: self.screen_disks("install"))
        b.focus_set()
        if any(d[2] for d in self.disks):
            self.button(fr, "UPDATE", lambda: self.screen_disks("update"), primary=False, size=20)
        self.button(fr, "REBOOT", self.reboot, primary=False, size=14)
        self.root.bind("<Return>", lambda e: self.root.focus_get().invoke()
                       if isinstance(self.root.focus_get(), tk.Button) else None)

    def screen_disks(self, mode):
        fr = self.clear()
        cands = [d for d in self.disks if mode == "install" or d[2]]
        title = "SELECT TARGET DISK" if mode == "install" else "SELECT INSTALLATION TO UPDATE"
        self.label(fr, title, 30, ACC, True)
        if not cands:
            self.label(fr, "No suitable disk found.", 18, ERR)
            self.button(fr, "BACK", self.screen_home, primary=False, size=18)
            return
        for dev, size, existing, model in cands:
            tag = "  [ArcadeOS]" if existing else ""
            self.button(fr, f"{dev}   {human(size)}   {model}{tag}",
                        lambda d=dev: self.screen_confirm(mode, d), primary=False, size=18)
        self.button(fr, "BACK", self.screen_home, primary=False, size=14)

    def screen_confirm(self, mode, dev):
        fr = self.clear()
        if mode == "install":
            self.label(fr, "WARNING", 40, ERR, True)
            self.label(fr, f"ALL DATA ON {dev} WILL BE ERASED.", 24, FG, True)
            self.label(fr, "The system will be encrypted and bound to THIS computer.", 16, DIM)
            self.button(fr, "ERASE AND INSTALL", lambda: self.start(mode, dev))
        else:
            self.label(fr, "UPDATE", 40, ACC, True)
            self.label(fr, f"System on {dev} will be replaced. Games and settings are kept.", 18)
            self.button(fr, "UPDATE NOW", lambda: self.start(mode, dev))
        self.button(fr, "BACK", self.screen_home, primary=False, size=16)

    def screen_progress(self):
        fr = self.clear()
        self.status = self.label(fr, "Starting...", 24, FG, True)
        w = int(900 * self.s)
        self.bar = tk.Canvas(fr, width=w, height=int(28 * self.s), bg=BG,
                             highlightthickness=2, highlightbackground=DIM)
        self.bar.pack(pady=int(20 * self.s))
        self.bar_fill = self.bar.create_rectangle(0, 0, 0, int(30 * self.s), fill=ACC, width=0)
        self.bar_w = w
        self.logbox = tk.Text(fr, width=100, height=10, bg=BG, fg=DIM, bd=0,
                              font=("DejaVu Sans Mono", int(10 * self.s)), highlightthickness=0)
        self.logbox.pack()

    def screen_done(self, mode):
        fr = self.clear()
        self.label(fr, "COMPLETE" if mode == "install" else "UPDATED", 50, ACC, True)
        rec = self.result.get("RECOVERY")
        if rec:
            self.label(fr, "RECOVERY KEY - write it down, it is shown only once:", 18, FG)
            self.label(fr, rec, 30, ACC, True)
            self.label(fr, "Needed if the motherboard, BIOS or network card changes.", 14, DIM)
        mok = self.result.get("MOKPASS")
        if mok:
            tk.Frame(fr, bg=BG, height=int(20 * self.s)).pack()
            self.label(fr, "ON THE NEXT BOOT a blue screen (MokManager) appears:", 18, FG, True)
            self.label(fr, "Enroll MOK  >  Continue  >  Yes  >  password:", 18, FG)
            self.label(fr, mok, 34, ACC, True)
            self.label(fr, "then Reboot. This lets the NVIDIA driver load with Secure Boot.", 14, DIM)
        for n in self.result.get("NOTES", []):
            self.label(fr, n, 13, ERR, wraplength=int(1400 * self.s))
        self.label(fr, "Remove the installer USB, then press REBOOT.", 16, FG)
        self.button(fr, "REBOOT", self.reboot)

    def screen_error(self, text):
        fr = self.clear()
        self.label(fr, "INSTALLATION FAILED", 40, ERR, True)
        self.label(fr, text, 18, FG, wraplength=int(1400 * self.s))
        log = tk.Text(fr, width=110, height=14, bg=BG, fg=DIM, bd=0,
                      font=("DejaVu Sans Mono", int(10 * self.s)))
        log.insert("end", "\n".join(self.lines[-200:]))
        log.see("end")
        log.pack(pady=int(10 * self.s))
        self.button(fr, "BACK", self.screen_home, primary=False, size=18)

    # ---------- backend ----------
    def start(self, mode, dev, extra=()):
        self.mode = mode
        self.result = {"NOTES": []}
        self.lines = []
        self.screen_progress()
        args = [BACKEND, f"--{mode}", "--disk", dev, *extra]
        self.proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     text=True, bufsize=1)
        threading.Thread(target=self.reader, daemon=True).start()

    def reader(self):
        for line in self.proc.stdout:
            self.q.put(line.rstrip("\n"))
        self.q.put(("EXIT", self.proc.wait()))

    def poll(self):
        try:
            while True:
                item = self.q.get_nowait()
                if isinstance(item, tuple):
                    if not self.result.get("DONE") and not self.result.get("ERROR"):
                        self.screen_error(f"installer exited with code {item[1]}")
                    continue
                self.handle(item)
        except queue.Empty:
            pass
        self.root.after(100, self.poll)

    def handle(self, line):
        self.lines.append(line)
        if line.startswith("@@PROGRESS "):
            _, pct, text = (line.split(" ", 2) + [""])[:3]
            self.status.config(text=text)
            self.bar.coords(self.bar_fill, 0, 0, self.bar_w * int(pct) / 100, int(30 * self.s))
        elif line.startswith("@@RECOVERY "):
            self.result["RECOVERY"] = line.split(" ", 1)[1]
        elif line.startswith("@@MOKPASS "):
            self.result["MOKPASS"] = line.split(" ", 1)[1]
        elif line.startswith("@@NOTE "):
            self.result["NOTES"].append(line.split(" ", 1)[1])
        elif line.startswith("@@ERROR "):
            self.result["ERROR"] = True
            msg = line.split(" ", 1)[1]
            if "hardware IDs of this board look generic" in msg:
                self.screen_weak()
            elif "Enter the recovery key" in msg:
                self.screen_recovery()
            else:
                self.screen_error(msg)
        elif line == "@@DONE":
            self.result["DONE"] = True
            self.screen_done(self.mode)
        elif hasattr(self, "logbox") and self.logbox.winfo_exists():
            self.logbox.insert("end", line + "\n")
            self.logbox.see("end")

    def screen_weak(self):
        fr = self.clear()
        self.label(fr, "WEAK HARDWARE ID", 36, ERR, True)
        self.label(fr, "This motherboard reports generic serial numbers.", 18)
        self.label(fr, "Binding to it is possible but easy to fake on another board.", 16, DIM)
        dev = self.target_dev()
        self.button(fr, "INSTALL ANYWAY",
                    lambda: self.start("install", dev, ["--force-weak-hwid"]))
        self.button(fr, "BACK", self.screen_home, primary=False, size=16)

    def target_dev(self):
        args = self.proc.args if self.proc else []
        return next((a for a in args if a.startswith("/dev/")), None)

    def screen_recovery(self):
        fr = self.clear()
        self.label(fr, "HARDWARE CHANGED", 36, ERR, True)
        self.label(fr, "Type the recovery key shown at installation:", 18)
        ent = tk.Entry(fr, font=self.f(28, True), width=40, bg=BG, fg=ACC,
                       insertbackground=ACC, justify="center", relief="flat",
                       highlightthickness=2, highlightbackground=ACC)
        ent.pack(pady=int(20 * self.s))
        ent.focus_set()
        dev = self.target_dev()
        go = lambda: self.start("update", dev, ["--recovery-key", ent.get().strip()])
        ent.bind("<Return>", lambda e: go())
        self.button(fr, "UNLOCK AND UPDATE", go)
        self.button(fr, "BACK", self.screen_home, primary=False, size=16)

    def reboot(self):
        subprocess.run(["systemctl", "reboot"])


if __name__ == "__main__":
    root = tk.Tk()
    root.title("ArcadeOS Installer")
    Installer(root)
    root.mainloop()
