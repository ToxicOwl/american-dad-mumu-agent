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
    private const string ApplicationVersion = "1.7.1";
    private const string ReleaseRepository = "ToxicOwl/american-dad-mumu-agent";
    private readonly string rootDirectory;
    private readonly string cycleScript;
    private readonly string hudScript;
    private readonly string hudStatsPath;
    private readonly string updateScript;
    private readonly string invasionCaptureScript;
    private readonly string invasionRunScript;
    private readonly string hapticAlertScript;
    private readonly NumericUpDown tournamentCount;
    private readonly Button dryRunButton;
    private readonly Button selectedRunsButton;
    private readonly Button untilFoodEndsButton;
    private readonly Button stopButton;
    private readonly Button refreshHudButton;
    private readonly Button resetStatsButton;
    private readonly Button checkUpdatesButton;
    private readonly Button stopHapticSoundButton;
    private readonly ComboBox invasionStep;
    private readonly Button captureInvasionButton;
    private readonly Button openInvasionCapturesButton;
    private readonly Label invasionInstruction;
    private readonly ComboBox invasionMode;
    private readonly Button invasionDryRunButton;
    private readonly Button runInvasionButton;
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
        invasionCaptureScript = Path.Combine(rootDirectory, "scripts", "invasion-capture.ps1");
        invasionRunScript = Path.Combine(rootDirectory, "scripts", "invasion-run.ps1");
        hapticAlertScript = Path.Combine(rootDirectory, "scripts", "haptic-alert.ps1");

        Text = "American Dad Arena Control";
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(1100, 750);
        Size = new Size(1180, 820);
        Font = new Font("Segoe UI", 9F, FontStyle.Regular, GraphicsUnit.Point);
        BackColor = Color.FromArgb(15, 23, 42);
        ForeColor = Color.FromArgb(241, 245, 249);

        var headerPanel = CreateSurfacePanel(new Point(0, 0), new Size(ClientSize.Width, 164), Color.FromArgb(24, 35, 55));
        headerPanel.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;

        var title = new Label
        {
            Text = "ARENA COMMAND CENTER",
            Font = new Font("Segoe UI", 19F, FontStyle.Bold, GraphicsUnit.Point),
            ForeColor = Color.White,
            AutoSize = true,
            Location = new Point(26, 18)
        };

        var description = new Label
        {
            Text = "FOOD ONLY  •  NO TICKETS  •  NO DIAMONDS  •  GUARDED LOCAL AUTOMATION",
            ForeColor = Color.FromArgb(163, 203, 239),
            AutoSize = true,
            Location = new Point(28, 56),
            Font = new Font("Segoe UI", 8.5F, FontStyle.Bold, GraphicsUnit.Point)
        };

        var versionBadge = new Label
        {
            Text = "LOCAL BUILD  v" + ApplicationVersion,
            ForeColor = Color.FromArgb(187, 247, 208),
            BackColor = Color.FromArgb(19, 78, 74),
            AutoSize = false,
            TextAlign = ContentAlignment.MiddleCenter,
            Size = new Size(168, 26),
            Location = new Point(28, 108),
            Font = new Font("Segoe UI", 8F, FontStyle.Bold, GraphicsUnit.Point)
        };

        var headerNote = new Label
        {
            Text = "Roger is watching the runs.",
            ForeColor = Color.FromArgb(203, 213, 225),
            AutoSize = true,
            Anchor = AnchorStyles.Top | AnchorStyles.Right,
            Location = new Point(ClientSize.Width - 472, 130),
            Font = new Font("Segoe UI", 8F, FontStyle.Italic, GraphicsUnit.Point)
        };

        var rogerHero = CreateRogerHero();
        rogerHero.Location = new Point(ClientSize.Width - 328, 0);
        rogerHero.Anchor = AnchorStyles.Top | AnchorStyles.Right;
        headerPanel.Controls.Add(title);
        headerPanel.Controls.Add(description);
        headerPanel.Controls.Add(versionBadge);
        headerPanel.Controls.Add(headerNote);
        headerPanel.Controls.Add(rogerHero);

        var hudPanel = new Panel
        {
            Location = new Point(22, 180),
            Size = new Size(ClientSize.Width - 44, 108),
            Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right,
            BackColor = Color.FromArgb(21, 56, 78),
            BorderStyle = BorderStyle.FixedSingle
        };

        foodValue = AddHudMetric(hudPanel, "FOOD", 14, 14, "—", Color.FromArgb(125, 211, 252));
        arenasValue = AddHudMetric(hudPanel, "ARENE", 164, 14, "0", Color.FromArgb(253, 224, 71));
        firstValue = AddHudMetric(hudPanel, "LOCUL 1", 314, 14, "0", Color.FromArgb(250, 204, 21), "trophy-1.png");
        secondValue = AddHudMetric(hudPanel, "LOCUL 2", 464, 14, "0", Color.FromArgb(226, 232, 240), "trophy-2.png");
        thirdValue = AddHudMetric(hudPanel, "LOCUL 3", 614, 14, "0", Color.FromArgb(251, 146, 60), "trophy-3.png");

        refreshHudButton = CreateButton("Refresh Food", new Point(780, 18), Color.FromArgb(14, 116, 144), new Size(138, 36));
        resetStatsButton = CreateButton("Reset stats", new Point(928, 18), Color.FromArgb(153, 55, 74), new Size(136, 36));
        stopHapticSoundButton = CreateButton("Stop alert sound", new Point(928, 65), Color.FromArgb(171, 49, 66), new Size(136, 29));
        stopHapticSoundButton.Font = new Font("Segoe UI", 8F, FontStyle.Bold, GraphicsUnit.Point);
        hudPanel.Controls.Add(refreshHudButton);
        hudPanel.Controls.Add(resetStatsButton);
        hudPanel.Controls.Add(stopHapticSoundButton);

        lastPlaceValue = new Label
        {
            Text = "Ultima poziție: —",
            ForeColor = Color.FromArgb(190, 210, 230),
            AutoSize = true,
            Location = new Point(782, 69),
            Font = new Font("Segoe UI", 8.5F, FontStyle.Regular, GraphicsUnit.Point)
        };
        hudPanel.Controls.Add(lastPlaceValue);

        var foodPanel = CreateSurfacePanel(new Point(22, 302), new Size(ClientSize.Width - 44, 80), Color.FromArgb(24, 39, 63));
        foodPanel.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
        var foodCaption = new Label
        {
            Text = "FOOD TOURNAMENTS  •  HAPTIC ALERT ARMED BETWEEN TOURNAMENTS",
            ForeColor = Color.FromArgb(148, 196, 255),
            AutoSize = true,
            Location = new Point(14, 11),
            Font = new Font("Segoe UI", 8F, FontStyle.Bold, GraphicsUnit.Point)
        };
        var countLabel = new Label
        {
            Text = "Număr turnee:",
            ForeColor = Color.FromArgb(226, 232, 240),
            AutoSize = true,
            Location = new Point(14, 39)
        };

        updateVersionLabel = new Label
        {
            Text = "Updates: checking GitHub…",
            ForeColor = Color.FromArgb(190, 210, 230),
            AutoSize = true,
            Location = new Point(862, 12),
            Anchor = AnchorStyles.Top | AnchorStyles.Right
        };

        tournamentCount = new NumericUpDown
        {
            Minimum = 1,
            Maximum = 50,
            Value = 1,
            Width = 80,
            Location = new Point(126, 35),
            Font = new Font("Segoe UI", 10F, FontStyle.Bold, GraphicsUnit.Point)
        };

        dryRunButton = CreateButton("Safe test", new Point(232, 27), Color.FromArgb(30, 100, 151), new Size(130, 38));
        selectedRunsButton = CreateButton("Run selected", new Point(372, 27), Color.FromArgb(22, 130, 88), new Size(150, 38));
        untilFoodEndsButton = CreateButton("Run until Food stops", new Point(532, 27), Color.FromArgb(185, 104, 30), new Size(174, 38));
        stopButton = CreateButton("Stop", new Point(716, 27), Color.FromArgb(190, 54, 74), new Size(96, 38));
        checkUpdatesButton = CreateButton("Check updates", new Point(822, 27), Color.FromArgb(79, 70, 229), new Size(130, 38));
        stopButton.Enabled = false;

        var invasionPanel = new Panel
        {
            Location = new Point(22, 394),
            Size = new Size(ClientSize.Width - 44, 96),
            Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right,
            BackColor = Color.FromArgb(55, 42, 82),
            BorderStyle = BorderStyle.FixedSingle
        };
        var invasionCaption = new Label
        {
            Text = "INVASION CALIBRATION — screenshot only, no taps",
            ForeColor = Color.FromArgb(228, 201, 255),
            AutoSize = true,
            Location = new Point(12, 8),
            Font = new Font("Segoe UI", 8F, FontStyle.Bold, GraphicsUnit.Point)
        };
        invasionStep = new ComboBox
        {
            DropDownStyle = ComboBoxStyle.DropDownList,
            Location = new Point(12, 29),
            Size = new Size(305, 24),
            Font = new Font("Segoe UI", 9F, FontStyle.Regular, GraphicsUnit.Point)
        };
        invasionStep.Items.AddRange(new object[]
        {
            "1. Map — Invasion icon visible",
            "2. Invasion panel — after icon",
            "3. UFO list — SHOW and UFO visible",
            "4. Attack choice — x10 and Attack visible",
            "5. Final result menu — after a manual battle",
            "Current screen — generic capture"
        });
        invasionStep.SelectedIndex = 0;
        captureInvasionButton = CreateButton("Capture selected", new Point(328, 27), Color.FromArgb(111, 76, 160), new Size(138, 28));
        openInvasionCapturesButton = CreateButton("Open captures", new Point(476, 27), Color.FromArgb(77, 105, 143), new Size(122, 28));
        invasionInstruction = new Label
        {
            Text = GetInvasionInstruction(0),
            ForeColor = Color.FromArgb(221, 227, 246),
            AutoSize = false,
            Size = new Size(325, 32),
            Location = new Point(610, 25),
            Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right,
            Font = new Font("Segoe UI", 8F, FontStyle.Regular, GraphicsUnit.Point)
        };
        invasionPanel.Controls.Add(invasionCaption);
        invasionPanel.Controls.Add(invasionStep);
        invasionPanel.Controls.Add(captureInvasionButton);
        invasionPanel.Controls.Add(openInvasionCapturesButton);
        invasionPanel.Controls.Add(invasionInstruction);

        var invasionRunPanel = new Panel
        {
            Location = new Point(22, 502),
            Size = new Size(ClientSize.Width - 44, 82),
            Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right,
            BackColor = Color.FromArgb(73, 47, 38),
            BorderStyle = BorderStyle.FixedSingle
        };
        var invasionRunCaption = new Label
        {
            Text = "INVASION RUN — one selected action only",
            ForeColor = Color.FromArgb(255, 214, 175),
            AutoSize = true,
            Location = new Point(12, 7),
            Font = new Font("Segoe UI", 8F, FontStyle.Bold, GraphicsUnit.Point)
        };
        invasionMode = new ComboBox
        {
            DropDownStyle = ComboBoxStyle.DropDownList,
            Location = new Point(12, 26),
            Size = new Size(255, 24),
            Font = new Font("Segoe UI", 9F, FontStyle.Regular, GraphicsUnit.Point)
        };
        invasionMode.Items.AddRange(new object[]
        {
            "All remaining rounds — BATTLE XN",
            "One round — ATTACK"
        });
        invasionMode.SelectedIndex = 0;
        invasionDryRunButton = CreateButton("Invasion safe test", new Point(278, 24), Color.FromArgb(88, 108, 157), new Size(150, 28));
        runInvasionButton = CreateButton("Run Invasion once", new Point(438, 24), Color.FromArgb(181, 102, 47), new Size(165, 28));
        var invasionRunInfo = new Label
        {
            Text = "Declines optional power with ATTACK; ADD and every post-result tap stay blocked.",
            ForeColor = Color.FromArgb(232, 221, 210),
            AutoSize = false,
            Size = new Size(325, 30),
            Location = new Point(614, 23),
            Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right,
            Font = new Font("Segoe UI", 8F, FontStyle.Regular, GraphicsUnit.Point)
        };
        invasionRunPanel.Controls.Add(invasionRunCaption);
        invasionRunPanel.Controls.Add(invasionMode);
        invasionRunPanel.Controls.Add(invasionDryRunButton);
        invasionRunPanel.Controls.Add(runInvasionButton);
        invasionRunPanel.Controls.Add(invasionRunInfo);

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
            Location = new Point(22, 596),
            Size = new Size(ClientSize.Width - 44, ClientSize.Height - 618),
            Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right,
            BackColor = BackColor
        };
        logPanel.Controls.Add(output);
        logPanel.Controls.Add(outputLabel);
        logPanel.Controls.Add(status);

        Controls.Add(headerPanel);
        Controls.Add(hudPanel);
        foodPanel.Controls.Add(foodCaption);
        foodPanel.Controls.Add(countLabel);
        foodPanel.Controls.Add(updateVersionLabel);
        foodPanel.Controls.Add(tournamentCount);
        foodPanel.Controls.Add(dryRunButton);
        foodPanel.Controls.Add(selectedRunsButton);
        foodPanel.Controls.Add(untilFoodEndsButton);
        foodPanel.Controls.Add(stopButton);
        foodPanel.Controls.Add(checkUpdatesButton);
        Controls.Add(foodPanel);
        Controls.Add(invasionPanel);
        Controls.Add(invasionRunPanel);
        Controls.Add(logPanel);

        dryRunButton.Click += async delegate { await StartDryRunAsync(); };
        selectedRunsButton.Click += async delegate { await StartSelectedRunsAsync(); };
        untilFoodEndsButton.Click += async delegate { await StartUntilFoodEndsAsync(); };
        stopButton.Click += delegate { StopCurrentRun(); };
        refreshHudButton.Click += async delegate { await RefreshFoodAsync(); };
        resetStatsButton.Click += async delegate { await ResetStatsAsync(); };
        stopHapticSoundButton.Click += delegate { StopHapticSound(); };
        checkUpdatesButton.Click += async delegate { await CheckForUpdatesAsync(true); };
        invasionStep.SelectedIndexChanged += delegate { invasionInstruction.Text = GetInvasionInstruction(invasionStep.SelectedIndex); };
        captureInvasionButton.Click += async delegate { await CaptureInvasionStepAsync(); };
        openInvasionCapturesButton.Click += delegate { OpenInvasionCaptures(); };
        invasionDryRunButton.Click += async delegate { await RunInvasionDryRunAsync(); };
        runInvasionButton.Click += async delegate { await RunInvasionLiveAsync(); };
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
        if (!File.Exists(invasionCaptureScript))
        {
            invasionInstruction.Text = "Invasion calibration module is unavailable.";
            invasionStep.Enabled = false;
            captureInvasionButton.Enabled = false;
            openInvasionCapturesButton.Enabled = false;
        }
        if (!File.Exists(invasionRunScript))
        {
            invasionMode.Enabled = false;
            invasionDryRunButton.Enabled = false;
            runInvasionButton.Enabled = false;
        }
        if (!File.Exists(hapticAlertScript))
        {
            stopHapticSoundButton.Enabled = false;
            AppendLine("WARNING: Haptic Alert module is unavailable.");
        }
    }

    private Panel CreateSurfacePanel(Point location, Size size, Color background)
    {
        return new Panel
        {
            Location = location,
            Size = size,
            BackColor = background,
            BorderStyle = BorderStyle.FixedSingle
        };
    }

    private PictureBox CreateRogerHero()
    {
        var hero = new PictureBox
        {
            Size = new Size(320, 164),
            BackColor = Color.Transparent,
            SizeMode = PictureBoxSizeMode.Zoom,
            TabStop = false
        };
        string assetPath = Path.Combine(rootDirectory, "assets", "roger-hud.png");
        if (File.Exists(assetPath))
        {
            using (var source = Image.FromFile(assetPath))
            {
                hero.Image = new Bitmap(source);
            }
        }
        else
        {
            hero.AccessibleName = "Roger image unavailable";
        }
        return hero;
    }

    private Label AddHudMetric(Panel panel, string caption, int x, int y, string value, Color valueColor, string trophyFile = null)
    {
        bool hasTrophy = !String.IsNullOrWhiteSpace(trophyFile);
        var card = new Panel
        {
            Location = new Point(x, y),
            Size = new Size(136, 78),
            BackColor = Color.FromArgb(17, 34, 54),
            BorderStyle = BorderStyle.FixedSingle
        };
        var accent = new Panel
        {
            Location = new Point(0, 0),
            Size = new Size(5, 78),
            BackColor = valueColor
        };
        var captionLabel = new Label
        {
            Text = caption,
            ForeColor = Color.FromArgb(148, 163, 184),
            AutoSize = true,
            Location = new Point(hasTrophy ? 64 : 14, 12),
            Font = new Font("Segoe UI", 8F, FontStyle.Bold, GraphicsUnit.Point)
        };
        var valueLabel = new Label
        {
            Text = value,
            ForeColor = valueColor,
            AutoSize = true,
            Location = new Point(hasTrophy ? 66 : 12, 33),
            Font = new Font("Segoe UI", 17F, FontStyle.Bold, GraphicsUnit.Point)
        };
        card.Controls.Add(accent);
        if (hasTrophy)
        {
            string trophyPath = Path.Combine(rootDirectory, "assets", trophyFile);
            if (File.Exists(trophyPath))
            {
                var trophy = new PictureBox
                {
                    Location = new Point(9, 10),
                    Size = new Size(48, 60),
                    SizeMode = PictureBoxSizeMode.Zoom,
                    BackColor = Color.Transparent,
                    TabStop = false
                };
                using (var source = Image.FromFile(trophyPath))
                {
                    trophy.Image = new Bitmap(source);
                }
                card.Controls.Add(trophy);
            }
        }
        card.Controls.Add(captionLabel);
        card.Controls.Add(valueLabel);
        panel.Controls.Add(card);
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
            UseVisualStyleBackColor = false,
            Cursor = Cursors.Hand
        };
        button.FlatAppearance.BorderColor = Color.FromArgb(226, 232, 240);
        button.FlatAppearance.MouseOverBackColor = Color.FromArgb(
            Math.Min(255, color.R + 18),
            Math.Min(255, color.G + 18),
            Math.Min(255, color.B + 18));
        button.FlatAppearance.MouseDownBackColor = Color.FromArgb(
            Math.Max(0, color.R - 18),
            Math.Max(0, color.G - 18),
            Math.Max(0, color.B - 18));
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

    private static string GetInvasionInstruction(int selectedIndex)
    {
        switch (selectedIndex)
        {
            case 0: return "Open MAP manually and place the Invasion icon fully on screen, then capture.";
            case 1: return "Tap Invasion manually, wait for its panel, then capture before SHOW.";
            case 2: return "Tap SHOW manually, wait for the UFO list, then capture. Do not select an UFO yet.";
            case 3: return "Select an UFO manually, then capture x10 and Attack. Do not press either button.";
            case 4: return "After one manual battle only, capture the final result menu before closing it.";
            default: return "Capture the screen currently visible in MuMu. No game input will be sent.";
        }
    }

    private static string GetInvasionStepName(int selectedIndex)
    {
        switch (selectedIndex)
        {
            case 0: return "01-map-invasion-icon";
            case 1: return "02-invasion-panel";
            case 2: return "03-show-ufo-list";
            case 3: return "04-attack-choice-x10-or-attack";
            case 4: return "05-final-result-menu";
            default: return "99-current-screen";
        }
    }

    private async Task CaptureInvasionStepAsync()
    {
        if (runningProcess != null)
        {
            MessageBox.Show("A process is already active. Wait for it to finish before capturing Invasion.", "Invasion calibration", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        if (!File.Exists(invasionCaptureScript))
        {
            MessageBox.Show("Missing Invasion capture module: " + invasionCaptureScript, "Invasion calibration", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        string step = GetInvasionStepName(invasionStep.SelectedIndex);
        SetStatus("Capturing Invasion calibration step — screenshot only, no game input.", Color.FromArgb(255, 226, 136));
        SetRunning(true);
        try
        {
            await RunInvasionCaptureScriptAsync(step);
            SetStatus("Invasion screenshot saved. Select the next requested view when ready.", Color.FromArgb(170, 224, 180));
        }
        catch (Exception ex)
        {
            SetStatus("Invasion capture failed: " + ex.Message, Color.FromArgb(255, 150, 150));
        }
        finally
        {
            SetRunning(false);
        }
    }

    private void OpenInvasionCaptures()
    {
        string folder = Path.Combine(rootDirectory, "captures", "invasion-calibration");
        Directory.CreateDirectory(folder);
        Process.Start(new ProcessStartInfo { FileName = folder, UseShellExecute = true });
    }

    private async Task RunInvasionCaptureScriptAsync(string step)
    {
        string arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + invasionCaptureScript + "\" -Step " + step;
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
        process.Exited += delegate { finished.TrySetResult(process.ExitCode); };

        runningProcess = process;
        AppendLine("Invasion calibration: " + step + " (screenshot only)");
        if (!process.Start()) throw new InvalidOperationException("PowerShell could not be started.");
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        int exitCode = await finished.Task;
        if (runningProcess == process) runningProcess = null;
        if (exitCode != 0) throw new InvalidOperationException("Invasion capture script exited with code " + exitCode + ". Read the activity log for details.");
    }

    private string SelectedInvasionMode()
    {
        return invasionMode.SelectedIndex == 1 ? "Single" : "AllRemaining";
    }

    private async Task RunInvasionDryRunAsync()
    {
        if (!EnsureInvasionReady()) return;
        SetStatus("Running Invasion safe test — no game input will be sent.", Color.FromArgb(255, 226, 136));
        SetRunning(true);
        try
        {
            await RunInvasionScriptAsync(SelectedInvasionMode(), true);
            SetStatus("Invasion safe test completed.", Color.FromArgb(170, 224, 180));
        }
        catch (Exception ex)
        {
            SetStatus("Invasion safe test stopped: " + ex.Message, Color.FromArgb(255, 150, 150));
        }
        finally
        {
            SetRunning(false);
        }
    }

    private async Task RunInvasionLiveAsync()
    {
        if (!EnsureInvasionReady()) return;
        string mode = SelectedInvasionMode();
        string selectedAction = mode == "AllRemaining" ? "the current BATTLE XN button (for example X10 or X9)" : "one ATTACK button";
        var confirmation = MessageBox.Show(
            "Start one Invasion action using " + selectedAction + "?\n\n" +
            "The game will spend only the Food amount visibly shown by that button. " +
            "The optional power prompt is declined using its green ATTACK button; ADD is blocked. " +
            "The bot stops after saving the first post-battle screen and will not tap the result screen.",
            "Confirm Invasion action",
            MessageBoxButtons.YesNo,
            MessageBoxIcon.Warning);
        if (confirmation != DialogResult.Yes) return;

        SetStatus("Running one guarded Invasion action. No post-result click will be sent.", Color.FromArgb(255, 226, 136));
        SetRunning(true);
        try
        {
            await RunInvasionScriptAsync(mode, false);
            SetStatus("Invasion action stopped safely after the captured post-battle screen.", Color.FromArgb(170, 224, 180));
        }
        catch (Exception ex)
        {
            SetStatus("Invasion stopped safely: " + ex.Message, Color.FromArgb(255, 150, 150));
        }
        finally
        {
            SetRunning(false);
        }
    }

    private bool EnsureInvasionReady()
    {
        if (runningProcess != null)
        {
            MessageBox.Show("A process is already active.", "Invasion", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return false;
        }
        if (!File.Exists(invasionRunScript))
        {
            MessageBox.Show("Missing Invasion script: " + invasionRunScript, "Invasion", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return false;
        }
        return true;
    }

    private async Task RunInvasionScriptAsync(string mode, bool dryRun)
    {
        string arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + invasionRunScript + "\" -Mode " + mode;
        if (dryRun) arguments += " -DryRun";
        else arguments += " -Confirm";

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
        process.Exited += delegate { finished.TrySetResult(process.ExitCode); };

        runningProcess = process;
        AppendLine("Launching: invasion-run.ps1 -Mode " + mode + (dryRun ? " -DryRun" : " -Confirm"));
        if (!process.Start()) throw new InvalidOperationException("PowerShell could not be started.");
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        int exitCode = await finished.Task;
        if (runningProcess == process) runningProcess = null;
        AppendLine("Invasion PowerShell exited with code " + exitCode + ".");
        if (exitCode != 0) throw new InvalidOperationException("Invasion script exited with code " + exitCode + ". Read the activity log for details.");
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

    private void StopHapticSound()
    {
        if (!File.Exists(hapticAlertScript)) return;
        try
        {
            var process = Process.Start(new ProcessStartInfo
            {
                FileName = PowerShellPath(),
                Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + hapticAlertScript + "\" -Mode StopSound",
                WorkingDirectory = rootDirectory,
                UseShellExecute = false,
                CreateNoWindow = true
            });
            if (process != null) process.WaitForExit(5000);
            AppendLine("Haptic Alert sound stop requested. The game dialog was not touched.");
            SetStatus("Haptic Alert sound stopped. The game dialog was not touched.", Color.FromArgb(255, 226, 136));
        }
        catch (Exception ex)
        {
            AppendLine("Haptic Alert sound stop warning: " + ex.Message);
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
        invasionStep.Enabled = !running && File.Exists(invasionCaptureScript);
        captureInvasionButton.Enabled = !running && File.Exists(invasionCaptureScript);
        openInvasionCapturesButton.Enabled = !running && File.Exists(invasionCaptureScript);
        invasionMode.Enabled = !running && File.Exists(invasionRunScript);
        invasionDryRunButton.Enabled = !running && File.Exists(invasionRunScript);
        runInvasionButton.Enabled = !running && File.Exists(invasionRunScript);
        stopHapticSoundButton.Enabled = File.Exists(hapticAlertScript);
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
