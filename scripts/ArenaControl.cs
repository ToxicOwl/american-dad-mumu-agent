using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

internal sealed class HudStats
{
    public int version { get; set; }
    public long? food_remaining { get; set; }
    public string food_updated_utc { get; set; }
    public int arenas_played { get; set; }
    public int place_1 { get; set; }
    public int place_2 { get; set; }
    public int place_3 { get; set; }
    public int? last_place { get; set; }
    public string updated_utc { get; set; }
}

internal sealed class UpdateInfo
{
    public string installed_version { get; set; }
    public string latest_version { get; set; }
    public string latest_tag { get; set; }
    public bool update_available { get; set; }
    public string notes { get; set; }
    public string published_at { get; set; }
}

internal sealed class ArenaControlForm : Form
{
    private const string ApplicationVersion = "1.4.0";
    private const string ReleaseRepository = "ToxicOwl/american-dad-mumu-agent";
    private readonly string rootDirectory;
    private readonly string cycleScript;
    private readonly string hudScript;
    private readonly string hudStatsPath;
    private readonly string updateScript;
    private readonly NumericUpDown tournamentCount;
    private readonly Button dryRunButton;
    private readonly Button selectedRunsButton;
    private readonly Button untilFoodEndsButton;
    private readonly Button stopButton;
    private readonly Button refreshHudButton;
    private readonly Button resetStatsButton;
    private readonly Button checkUpdatesButton;
    private readonly Label updateVersionLabel;
    private readonly RichTextBox output;
    private readonly Label status;
    private readonly Label foodValue;
    private readonly Label arenasValue;
    private readonly Label firstValue;
    private readonly Label secondValue;
    private readonly Label thirdValue;
    private readonly Label lastPlaceValue;
    private Process runningProcess;
    private volatile bool stopRequested;

    public ArenaControlForm()
    {
        rootDirectory = AppDomain.CurrentDomain.BaseDirectory;
        cycleScript = Path.Combine(rootDirectory, "scripts", "arena-cycle.ps1");
        hudScript = Path.Combine(rootDirectory, "scripts", "arena-hud.ps1");
        hudStatsPath = Path.Combine(rootDirectory, "logs", "arena-hud-stats.json");
        updateScript = Path.Combine(rootDirectory, "scripts", "update-agent.ps1");

        Text = "American Dad Arena Control";
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(920, 650);
        Size = new Size(980, 740);
        Font = new Font("Segoe UI", 9F, FontStyle.Regular, GraphicsUnit.Point);
        BackColor = Color.FromArgb(31, 38, 49);
        ForeColor = Color.White;

        var title = new Label
        {
            Text = "American Dad Arena — local control",
            Font = new Font("Segoe UI", 16F, FontStyle.Bold, GraphicsUnit.Point),
            ForeColor = Color.White,
            AutoSize = true,
            Location = new Point(20, 18)
        };

        var description = new Label
        {
            Text = "Food only • no Tickets • no diamonds • stops safely on an unrecognized screen • v" + ApplicationVersion,
            ForeColor = Color.FromArgb(190, 210, 230),
            AutoSize = true,
            Location = new Point(22, 51)
        };

        var hudPanel = new Panel
        {
            Location = new Point(22, 80),
            Size = new Size(ClientSize.Width - 44, 78),
            Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right,
            BackColor = Color.FromArgb(21, 56, 78),
            BorderStyle = BorderStyle.FixedSingle
        };

        foodValue = AddHudMetric(hudPanel, "FOOD", 16, 12, "—", Color.FromArgb(121, 212, 255));
        arenasValue = AddHudMetric(hudPanel, "ARENE JUCATE", 180, 12, "0", Color.FromArgb(255, 218, 105));
        firstValue = AddHudMetric(hudPanel, "LOCUL 1", 370, 12, "0", Color.FromArgb(255, 214, 69));
        secondValue = AddHudMetric(hudPanel, "LOCUL 2", 495, 12, "0", Color.FromArgb(208, 218, 230));
        thirdValue = AddHudMetric(hudPanel, "LOCUL 3", 620, 12, "0", Color.FromArgb(219, 153, 99));

        refreshHudButton = CreateButton("Refresh Food", new Point(734, 11), Color.FromArgb(61, 117, 180), new Size(106, 30));
        resetStatsButton = CreateButton("Reset stats", new Point(844, 11), Color.FromArgb(128, 78, 78), new Size(102, 30));
        hudPanel.Controls.Add(refreshHudButton);
        hudPanel.Controls.Add(resetStatsButton);

        lastPlaceValue = new Label
        {
            Text = "Ultima poziție: —",
            ForeColor = Color.FromArgb(190, 210, 230),
            AutoSize = true,
            Location = new Point(734, 48),
            Font = new Font("Segoe UI", 8.5F, FontStyle.Regular, GraphicsUnit.Point)
        };
        hudPanel.Controls.Add(lastPlaceValue);

        var countLabel = new Label
        {
            Text = "Număr turnee Food:",
            ForeColor = Color.White,
            AutoSize = true,
            Location = new Point(22, 177)
        };

        updateVersionLabel = new Label
        {
            Text = "Updates: checking GitHub…",
            ForeColor = Color.FromArgb(190, 210, 230),
            AutoSize = true,
            Location = new Point(300, 177)
        };

        tournamentCount = new NumericUpDown
        {
            Minimum = 1,
            Maximum = 50,
            Value = 1,
            Width = 80,
            Location = new Point(172, 173),
            Font = new Font("Segoe UI", 10F, FontStyle.Bold, GraphicsUnit.Point)
        };

        dryRunButton = CreateButton("Safe test (no taps)", new Point(22, 215), Color.FromArgb(61, 117, 180), new Size(174, 38));
        selectedRunsButton = CreateButton("Run selected tournaments", new Point(205, 215), Color.FromArgb(45, 166, 91), new Size(220, 38));
        untilFoodEndsButton = CreateButton("Run until Food stops", new Point(434, 215), Color.FromArgb(204, 132, 44), new Size(210, 38));
        stopButton = CreateButton("Stop", new Point(653, 215), Color.FromArgb(188, 66, 66), new Size(170, 38));
        checkUpdatesButton = CreateButton("Check updates", new Point(832, 215), Color.FromArgb(88, 91, 180), new Size(124, 38));
        stopButton.Enabled = false;

        status = new Label
        {
            Text = "Ready. Start from the game base or the Food / Ticket selector.",
            ForeColor = Color.FromArgb(170, 224, 180),
            AutoSize = false,
            Height = 34,
            Dock = DockStyle.Top,
            Padding = new Padding(0, 7, 0, 0)
        };

        var outputLabel = new Label
        {
            Text = "Activity log",
            Font = new Font("Segoe UI", 10F, FontStyle.Bold, GraphicsUnit.Point),
            ForeColor = Color.White,
            Dock = DockStyle.Top,
            Height = 28,
            Padding = new Padding(0, 5, 0, 0)
        };

        output = new RichTextBox
        {
            Dock = DockStyle.Fill,
            ReadOnly = true,
            BackColor = Color.FromArgb(17, 22, 29),
            ForeColor = Color.FromArgb(214, 231, 245),
            BorderStyle = BorderStyle.FixedSingle,
            Font = new Font("Consolas", 9F, FontStyle.Regular, GraphicsUnit.Point),
            HideSelection = false
        };

        var logPanel = new Panel
        {
            Location = new Point(22, 272),
            Size = new Size(ClientSize.Width - 44, ClientSize.Height - 294),
            Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right,
            BackColor = BackColor
        };
        logPanel.Controls.Add(output);
        logPanel.Controls.Add(outputLabel);
        logPanel.Controls.Add(status);

        Controls.Add(title);
        Controls.Add(description);
        Controls.Add(hudPanel);
        Controls.Add(countLabel);
        Controls.Add(updateVersionLabel);
        Controls.Add(tournamentCount);
        Controls.Add(dryRunButton);
        Controls.Add(selectedRunsButton);
        Controls.Add(untilFoodEndsButton);
        Controls.Add(stopButton);
        Controls.Add(checkUpdatesButton);
        Controls.Add(logPanel);

        dryRunButton.Click += async delegate { await StartDryRunAsync(); };
        selectedRunsButton.Click += async delegate { await StartSelectedRunsAsync(); };
        untilFoodEndsButton.Click += async delegate { await StartUntilFoodEndsAsync(); };
        stopButton.Click += delegate { StopCurrentRun(); };
        refreshHudButton.Click += async delegate { await RefreshFoodAsync(); };
        resetStatsButton.Click += async delegate { await ResetStatsAsync(); };
        checkUpdatesButton.Click += async delegate { await CheckForUpdatesAsync(true); };
        FormClosing += delegate { StopCurrentRun(); };
        Shown += async delegate { await CheckForUpdatesAsync(false); await RefreshFoodAsync(); };

        AppendLine("Application folder: " + rootDirectory);
        RefreshHudFromDisk();

        if (!File.Exists(cycleScript) || !File.Exists(hudScript))
        {
            AppendLine("ERROR: Missing scripts\\arena-cycle.ps1 or scripts\\arena-hud.ps1. Keep the EXE inside D:\\Games\\AmericanBot.");
            SetStatus("Missing automation script.", Color.FromArgb(255, 150, 150));
            dryRunButton.Enabled = false;
            selectedRunsButton.Enabled = false;
            untilFoodEndsButton.Enabled = false;
            refreshHudButton.Enabled = false;
            resetStatsButton.Enabled = false;
        }
        if (!File.Exists(updateScript))
        {
            updateVersionLabel.Text = "Updates: module unavailable";
            checkUpdatesButton.Enabled = false;
        }
    }

    private Label AddHudMetric(Panel panel, string caption, int x, int y, string value, Color valueColor)
    {
        var captionLabel = new Label
        {
            Text = caption,
            ForeColor = Color.FromArgb(174, 205, 226),
            AutoSize = true,
            Location = new Point(x, y),
            Font = new Font("Segoe UI", 8F, FontStyle.Bold, GraphicsUnit.Point)
        };
        var valueLabel = new Label
        {
            Text = value,
            ForeColor = valueColor,
            AutoSize = true,
            Location = new Point(x, y + 24),
            Font = new Font("Segoe UI", 16F, FontStyle.Bold, GraphicsUnit.Point)
        };
        panel.Controls.Add(captionLabel);
        panel.Controls.Add(valueLabel);
        return valueLabel;
    }

    private Button CreateButton(string text, Point location, Color color, Size size)
    {
        var button = new Button
        {
            Text = text,
            Location = location,
            Size = size,
            BackColor = color,
            ForeColor = Color.White,
            FlatStyle = FlatStyle.Flat,
            Font = new Font("Segoe UI", 9F, FontStyle.Bold, GraphicsUnit.Point),
            UseVisualStyleBackColor = false
        };
        button.FlatAppearance.BorderColor = Color.FromArgb(230, 240, 250);
        return button;
    }

    private async Task RefreshFoodAsync()
    {
        if (runningProcess != null) return;
        try
        {
            SetStatus("Reading Food from the game screen — no tap will be sent.", Color.FromArgb(255, 226, 136));
            await RunHudScriptAsync("-RefreshFood");
            RefreshHudFromDisk();
            SetStatus("Food counter updated.", Color.FromArgb(170, 224, 180));
        }
        catch (Exception ex)
        {
            SetStatus("Food refresh failed: " + ex.Message, Color.FromArgb(255, 150, 150));
        }
    }

    private async Task ResetStatsAsync()
    {
        if (runningProcess != null) return;
        var confirmation = MessageBox.Show(
            "Reset only Arene jucate and Locul 1 / 2 / 3 counters?\n\nFood is kept. The counters will begin again from zero.",
            "Confirm HUD reset",
            MessageBoxButtons.YesNo,
            MessageBoxIcon.Warning);
        if (confirmation != DialogResult.Yes) return;

        try
        {
            await RunHudScriptAsync("-ResetStats");
            RefreshHudFromDisk();
            SetStatus("Arena counters reset. Food was kept.", Color.FromArgb(170, 224, 180));
        }
        catch (Exception ex)
        {
            SetStatus("HUD reset failed: " + ex.Message, Color.FromArgb(255, 150, 150));
        }
    }

    private async Task CheckForUpdatesAsync(bool interactive)
    {
        if (runningProcess != null)
        {
            if (interactive) MessageBox.Show("Stop the active Arena run before checking for updates.", "Arena updates", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        if (!File.Exists(updateScript))
        {
            updateVersionLabel.Text = "Updates: module unavailable";
            return;
        }

        checkUpdatesButton.Enabled = false;
        updateVersionLabel.Text = "Updates: checking GitHub…";
        try
        {
            string arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + updateScript + "\"" +
                " -Mode Check" +
                " -Repository " + ReleaseRepository +
                " -CurrentVersion " + ApplicationVersion;
            string response = await RunPowerShellCaptureAsync(arguments);
            var serializer = new JavaScriptSerializer();
            var info = serializer.Deserialize<UpdateInfo>(response);
            if (info == null || String.IsNullOrEmpty(info.latest_version)) throw new InvalidOperationException("GitHub returned an invalid update response.");

            if (!info.update_available)
            {
                updateVersionLabel.Text = "Updates: v" + ApplicationVersion + " is current";
                if (interactive) MessageBox.Show("You already have the latest version: v" + ApplicationVersion + ".", "Arena updates", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            updateVersionLabel.Text = "Updates: v" + info.latest_version + " available";
            if (!interactive) return;

            string releaseNotes = String.IsNullOrWhiteSpace(info.notes) ? "No release notes were provided." : info.notes.Trim();
            var confirmation = MessageBox.Show(
                "Version v" + info.latest_version + " is available.\n\n" + releaseNotes +
                "\n\nInstall it now?\n\nYour config.json, logs, captures and Python environment will be kept.",
                "Install Arena update",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Information);
            if (confirmation != DialogResult.Yes) return;

            await StartUpdateInstallerAsync();
        }
        catch (Exception ex)
        {
            updateVersionLabel.Text = "Updates: unavailable";
            if (interactive) MessageBox.Show("Could not check GitHub updates.\n\n" + ex.Message, "Arena updates", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        finally
        {
            if (!IsDisposed && runningProcess == null) checkUpdatesButton.Enabled = true;
        }
    }

    private async Task StartUpdateInstallerAsync()
    {
        if (runningProcess != null) return;
        SetStatus("Preparing confirmed update. The application will restart when it is finished.", Color.FromArgb(255, 226, 136));
        string arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + updateScript + "\"" +
            " -Mode Install" +
            " -Repository " + ReleaseRepository +
            " -CurrentVersion " + ApplicationVersion +
            " -ParentProcessId " + Process.GetCurrentProcess().Id;

        var startInfo = new ProcessStartInfo
        {
            FileName = PowerShellPath(),
            Arguments = arguments,
            WorkingDirectory = rootDirectory,
            UseShellExecute = false,
            CreateNoWindow = false
        };
        var installer = Process.Start(startInfo);
        if (installer == null) throw new InvalidOperationException("The update installer could not be started.");
        await Task.Delay(250);
        Close();
    }

    private async Task StartDryRunAsync()
    {
        if (!EnsureReady()) return;
        SetStatus("Running safe test — no game input will be sent.", Color.FromArgb(255, 226, 136));
        SetRunning(true);
        try
        {
            await RunCycleAsync(1, true);
            SetStatus("Safe test completed.", Color.FromArgb(170, 224, 180));
        }
        catch (Exception ex)
        {
            SetStatus("Safe test stopped: " + ex.Message, Color.FromArgb(255, 150, 150));
        }
        finally
        {
            RefreshHudFromDisk();
            SetRunning(false);
        }
    }

    private async Task StartSelectedRunsAsync()
    {
        if (!EnsureReady()) return;
        int count = Decimal.ToInt32(tournamentCount.Value);
        var confirmation = MessageBox.Show(
            "Start " + count + " Food tournament(s)?\n\nEach new tournament spends 10,000 Food. Tickets and diamonds remain blocked.",
            "Confirm Food tournament run",
            MessageBoxButtons.YesNo,
            MessageBoxIcon.Warning);
        if (confirmation != DialogResult.Yes) return;

        SetStatus("Running " + count + " selected Food tournament(s).", Color.FromArgb(255, 226, 136));
        SetRunning(true);
        try
        {
            await RunCycleAsync(count, false);
            SetStatus("Selected run finished or stopped safely.", Color.FromArgb(170, 224, 180));
        }
        catch (Exception ex)
        {
            SetStatus("Run stopped safely: " + ex.Message, Color.FromArgb(255, 150, 150));
        }
        finally
        {
            RefreshHudFromDisk();
            SetRunning(false);
        }
    }

    private async Task StartUntilFoodEndsAsync()
    {
        if (!EnsureReady()) return;
        var confirmation = MessageBox.Show(
            "Run Food tournaments one at a time until the game can no longer start a new Food tournament?\n\nEach attempt can spend 10,000 Food. The process stops on the first game or recognition error. Tickets and diamonds remain blocked.",
            "Confirm run until Food stops",
            MessageBoxButtons.YesNo,
            MessageBoxIcon.Warning);
        if (confirmation != DialogResult.Yes) return;

        stopRequested = false;
        SetStatus("Running tournaments until Food or the game stops the next start.", Color.FromArgb(255, 226, 136));
        SetRunning(true);
        int completed = 0;
        try
        {
            while (!stopRequested)
            {
                AppendLine("");
                AppendLine("=== Food loop: starting tournament " + (completed + 1) + " ===");
                int exitCode = await RunCycleAsync(1, false);
                RefreshHudFromDisk();
                if (stopRequested) break;
                if (exitCode != 0)
                {
                    AppendLine("Food loop stopped after " + completed + " completed tournament(s); the game or script rejected the next start.");
                    SetStatus("Stopped safely after " + completed + " completed tournament(s).", Color.FromArgb(255, 226, 136));
                    return;
                }
                completed++;
            }
            SetStatus("Stopped by user after " + completed + " completed tournament(s).", Color.FromArgb(255, 226, 136));
        }
        catch (Exception ex)
        {
            SetStatus("Food loop stopped safely: " + ex.Message, Color.FromArgb(255, 150, 150));
        }
        finally
        {
            RefreshHudFromDisk();
            SetRunning(false);
        }
    }

    private bool EnsureReady()
    {
        if (runningProcess != null)
        {
            MessageBox.Show("A run is already active.", "Arena Control", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return false;
        }
        if (!File.Exists(cycleScript) || !File.Exists(hudScript))
        {
            MessageBox.Show("Missing Arena scripts in: " + Path.Combine(rootDirectory, "scripts"), "Arena Control", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return false;
        }
        return true;
    }

    private async Task<int> RunCycleAsync(int tournaments, bool dryRun)
    {
        string arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + cycleScript + "\"" +
            " -Tournaments " + tournaments +
            " -BattlesPerTournament 5" +
            " -StageWaitTimeoutSeconds 180" +
            " -MatchmakingTimeoutSeconds 120";
        if (dryRun) arguments += " -DryRun";

        var startInfo = new ProcessStartInfo
        {
            FileName = PowerShellPath(),
            Arguments = arguments,
            WorkingDirectory = rootDirectory,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };

        var process = new Process();
        process.StartInfo = startInfo;
        process.EnableRaisingEvents = true;
        var finished = new TaskCompletionSource<int>();

        process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs args)
        {
            if (!String.IsNullOrEmpty(args.Data)) AppendLine(args.Data);
        };
        process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs args)
        {
            if (!String.IsNullOrEmpty(args.Data)) AppendLine("ERROR: " + args.Data);
        };
        process.Exited += delegate
        {
            try { finished.TrySetResult(process.ExitCode); }
            catch (Exception ex) { finished.TrySetException(ex); }
        };

        runningProcess = process;
        stopRequested = false;
        AppendLine("Launching: arena-cycle.ps1 -Tournaments " + tournaments + (dryRun ? " -DryRun" : ""));
        if (!process.Start()) throw new InvalidOperationException("PowerShell could not be started.");
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        int exitCode = await finished.Task;
        if (runningProcess == process) runningProcess = null;
        AppendLine("PowerShell exited with code " + exitCode + ".");
        return exitCode;
    }

    private async Task RunHudScriptAsync(string hudArguments)
    {
        if (!File.Exists(hudScript)) throw new FileNotFoundException("Missing HUD script", hudScript);
        var startInfo = new ProcessStartInfo
        {
            FileName = PowerShellPath(),
            Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + hudScript + "\" " + hudArguments,
            WorkingDirectory = rootDirectory,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };

        var outputText = new StringBuilder();
        var errorText = new StringBuilder();
        var process = new Process();
        process.StartInfo = startInfo;
        process.EnableRaisingEvents = true;
        var finished = new TaskCompletionSource<int>();
        process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs args)
        {
            if (!String.IsNullOrEmpty(args.Data)) outputText.AppendLine(args.Data);
        };
        process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs args)
        {
            if (!String.IsNullOrEmpty(args.Data)) errorText.AppendLine(args.Data);
        };
        process.Exited += delegate { finished.TrySetResult(process.ExitCode); };

        if (!process.Start()) throw new InvalidOperationException("PowerShell could not be started.");
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        int exitCode = await finished.Task;
        if (exitCode != 0)
        {
            string detail = errorText.ToString().Trim();
            if (String.IsNullOrEmpty(detail)) detail = outputText.ToString().Trim();
            throw new InvalidOperationException(String.IsNullOrEmpty(detail) ? "HUD command failed." : detail);
        }
    }

    private async Task<string> RunPowerShellCaptureAsync(string arguments)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = PowerShellPath(),
            Arguments = arguments,
            WorkingDirectory = rootDirectory,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };

        var outputText = new StringBuilder();
        var errorText = new StringBuilder();
        var process = new Process();
        process.StartInfo = startInfo;
        process.EnableRaisingEvents = true;
        var finished = new TaskCompletionSource<int>();
        process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs args)
        {
            if (!String.IsNullOrEmpty(args.Data)) outputText.AppendLine(args.Data);
        };
        process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs args)
        {
            if (!String.IsNullOrEmpty(args.Data)) errorText.AppendLine(args.Data);
        };
        process.Exited += delegate { finished.TrySetResult(process.ExitCode); };

        if (!process.Start()) throw new InvalidOperationException("PowerShell could not be started.");
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        int exitCode = await finished.Task;
        if (exitCode != 0)
        {
            string detail = errorText.ToString().Trim();
            if (String.IsNullOrEmpty(detail)) detail = outputText.ToString().Trim();
            throw new InvalidOperationException(String.IsNullOrEmpty(detail) ? "Update check failed." : detail);
        }

        string response = outputText.ToString().Trim();
        if (String.IsNullOrEmpty(response)) throw new InvalidOperationException("GitHub did not return update data.");
        string[] lines = response.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
        return lines[lines.Length - 1].Trim();
    }

    private void RefreshHudFromDisk()
    {
        try
        {
            if (!File.Exists(hudStatsPath))
            {
                foodValue.Text = "—";
                arenasValue.Text = "0";
                firstValue.Text = "0";
                secondValue.Text = "0";
                thirdValue.Text = "0";
                lastPlaceValue.Text = "Ultima poziție: —";
                return;
            }

            var serializer = new JavaScriptSerializer();
            var stats = serializer.Deserialize<HudStats>(File.ReadAllText(hudStatsPath));
            foodValue.Text = stats.food_remaining.HasValue ? String.Format("{0:N0}", stats.food_remaining.Value) : "—";
            arenasValue.Text = stats.arenas_played.ToString();
            firstValue.Text = stats.place_1.ToString();
            secondValue.Text = stats.place_2.ToString();
            thirdValue.Text = stats.place_3.ToString();
            lastPlaceValue.Text = stats.last_place.HasValue ? "Ultima poziție: " + stats.last_place.Value : "Ultima poziție: —";
        }
        catch (Exception ex)
        {
            AppendLine("HUD read warning: " + ex.Message);
        }
    }

    private static string PowerShellPath()
    {
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell\\v1.0\\powershell.exe");
    }

    private void StopCurrentRun()
    {
        stopRequested = true;
        var process = runningProcess;
        if (process != null && !process.HasExited)
        {
            AppendLine("Stop requested. Ending current PowerShell process and restoring monitor mode.");
            try { process.Kill(); }
            catch (Exception ex) { AppendLine("Unable to stop process: " + ex.Message); }
            ForceMonitorMode();
        }
    }

    private void ForceMonitorMode()
    {
        try
        {
            string configPath = Path.Combine(rootDirectory, "config.json");
            string command = "$p='" + configPath + "';" +
                "$c=Get-Content -LiteralPath $p -Raw|ConvertFrom-Json;" +
                "$c.safety.mode='monitor';$c.safety.forbid_diamond_spend=$true;" +
                "$c|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $p -Encoding utf8";
            var safetyProcess = Process.Start(new ProcessStartInfo
            {
                FileName = PowerShellPath(),
                Arguments = "-NoProfile -ExecutionPolicy Bypass -Command \"" + command + "\"",
                UseShellExecute = false,
                CreateNoWindow = true
            });
            if (safetyProcess != null) safetyProcess.WaitForExit(5000);
            AppendLine("Safety restored: config.json is now in monitor mode.");
        }
        catch (Exception ex)
        {
            AppendLine("WARNING: Could not confirm monitor mode: " + ex.Message);
        }
    }

    private void SetRunning(bool running)
    {
        if (InvokeRequired)
        {
            BeginInvoke(new Action<bool>(SetRunning), running);
            return;
        }
        dryRunButton.Enabled = !running;
        selectedRunsButton.Enabled = !running;
        untilFoodEndsButton.Enabled = !running;
        tournamentCount.Enabled = !running;
        refreshHudButton.Enabled = !running;
        resetStatsButton.Enabled = !running;
        checkUpdatesButton.Enabled = !running && File.Exists(updateScript);
        stopButton.Enabled = running;
    }

    private void SetStatus(string message, Color color)
    {
        if (InvokeRequired)
        {
            BeginInvoke(new Action<string, Color>(SetStatus), message, color);
            return;
        }
        status.Text = message;
        status.ForeColor = color;
    }

    private void AppendLine(string text)
    {
        if (InvokeRequired)
        {
            BeginInvoke(new Action<string>(AppendLine), text);
            return;
        }
        output.AppendText(text + Environment.NewLine);
        output.SelectionStart = output.TextLength;
        output.ScrollToCaret();
    }

    [STAThread]
    private static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new ArenaControlForm());
    }
}
