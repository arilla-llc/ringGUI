<# : batch
@echo off
set "RINGGUI_PATH=%~f0"
start "" conhost.exe --headless powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -Command "try { iex ([IO.File]::ReadAllText($env:RINGGUI_PATH, [Text.Encoding]::UTF8)) } catch { Add-Type -AssemblyName PresentationFramework; [void][Windows.MessageBox]::Show(($_ | Out-String), 'RingGUI') }"
exit /b
#>

# =====================================================================
#  Лицензии 1С — красивая оболочка над утилитой ring.
#  Один файл: двойной клик по RingGUI.cmd — и всё.
# =====================================================================

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$LogFile = Join-Path $env:TEMP 'RingGUI.log'
function Write-Log($m) { try { Add-Content -Path $LogFile -Value ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $m) -Encoding UTF8 } catch {} }
function Show-Error($err) {
    $msg = ($err | Out-String).Trim()
    Write-Log $msg
    [void][Windows.MessageBox]::Show("Что-то пошло не так:`n`n$msg`n`nЛог: $LogFile", 'Лицензии 1С', 'OK', 'Error')
}
function Safe([scriptblock]$sb) { try { & $sb } catch { Hide-Busy; Show-Error $_ } }

# ---------- Окружение ----------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$script:IsAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Свежие PATH и JAVA_HOME из реестра — не нужно ничего перезапускать после установки Java/ring
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
$jh = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'User')
if (-not $jh) { $jh = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'Machine') }
if ($jh) { $env:JAVA_HOME = $jh }
# Если java нет в PATH, но JAVA_HOME верный — подставляем его, чтобы ring запускался
if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME 'bin\java.exe'))) { $env:Path = (Join-Path $env:JAVA_HOME 'bin') + ';' + $env:Path }

$LicDir      = Join-Path $env:ProgramData '1C\licenses'
$ProfileDir  = Join-Path $env:APPDATA 'RingGUI'
$ProfileFile = Join-Path $ProfileDir 'profile.json'

function Find-Ring {
    $c = Get-Command ring -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    foreach ($root in @("$env:ProgramFiles\1C\1CE\components", "${env:ProgramFiles(x86)}\1C\1CE\components")) {
        if ($root -and (Test-Path $root)) {
            $f = Get-ChildItem $root -Recurse -Filter ring.cmd -ErrorAction SilentlyContinue |
                 Sort-Object FullName -Descending | Select-Object -First 1
            if ($f) { return $f.FullName }
        }
    }
    return $null
}
$script:RingPath = Find-Ring

# ---------- Запуск процессов ----------
function Pump { [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Background) }

function Decode([byte[]]$b) {
    if (-not $b -or $b.Length -eq 0) { return '' }
    try   { return (New-Object Text.UTF8Encoding($false, $true)).GetString($b) }
    catch { return [Text.Encoding]::GetEncoding(1251).GetString($b) }
}

function Quote-Arg([string]$s) {
    if ($null -eq $s) { $s = '' }
    $s = [regex]::Replace($s, '"([^"]*)"', '«$1»').Replace('"', '')   # ООО "Ромашка" -> ООО «Ромашка»
    return '"' + $s + '"'
}

function Invoke-Cmd([string]$cmdLine) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName  = $env:ComSpec
    $psi.Arguments = "/d /s /c `"$cmdLine`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    $out = New-Object IO.MemoryStream
    $err = New-Object IO.MemoryStream
    $t1 = $p.StandardOutput.BaseStream.CopyToAsync($out)
    $t2 = $p.StandardError.BaseStream.CopyToAsync($err)
    while (-not $p.HasExited) { Pump; Start-Sleep -Milliseconds 40 }
    [void]$t1.Wait(5000); [void]$t2.Wait(5000)
    $p.WaitForExit()
    [pscustomobject]@{ Code = $p.ExitCode; Out = (Decode $out.ToArray()).Trim(); Err = (Decode $err.ToArray()).Trim() }
}

function Build-RingArgs([string[]]$RingArgs) {
    ($RingArgs | ForEach-Object { if ($_ -like '--*' -or $_ -match '^[a-z]+$') { $_ } else { Quote-Arg $_ } }) -join ' '
}
function Invoke-Ring([string[]]$RingArgs) { Invoke-Cmd ('"' + $script:RingPath + '" ' + (Build-RingArgs $RingArgs)) }

function Format-Result($r) {
    $t = @()
    if ($r.Out) { $t += $r.Out }
    if ($r.Err) { $t += $r.Err }
    if (-not $t) { $t += '(утилита ничего не вывела)' }
    $t -join "`n`n"
}

# ---------- Интерфейс ----------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Лицензии 1С" Width="1080" Height="720" MinWidth="900" MinHeight="600"
        WindowStartupLocation="CenterScreen" Background="#F3F4F6"
        FontFamily="Segoe UI" FontSize="14" Foreground="#111827" UseLayoutRounding="True">
  <Window.Resources>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="#E5E7EB"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="22"/>
    </Style>
    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="FontSize" Value="26"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Sub" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#6B7280"/>
      <Setter Property="Margin" Value="0,4,0,0"/>
    </Style>
    <Style x:Key="H2" TargetType="TextBlock">
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Hint" TargetType="TextBlock">
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Foreground" Value="#6B7280"/>
      <Setter Property="Margin" Value="0,3,0,18"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="Icon" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Margin" Value="0,1,8,0"/>
    </Style>

    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Background" Value="White"/>
      <Setter Property="Foreground" Value="#111827"/>
      <Setter Property="BorderBrush" Value="#D1D5DB"/>
      <Setter Property="Padding" Value="16,9"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.7"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#2563EB"/>
      <Setter Property="BorderBrush" Value="#2563EB"/>
      <Setter Property="Foreground" Value="White"/>
    </Style>
    <Style x:Key="BtnDanger" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Foreground" Value="#DC2626"/>
    </Style>
    <Style x:Key="BtnSide" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#374151"/>
      <Setter Property="BorderBrush" Value="#4B5563"/>
      <Setter Property="Foreground" Value="#F9FAFB"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="Margin" Value="0"/>
    </Style>

    <Style x:Key="Input" TargetType="TextBox">
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="#D1D5DB"/>
      <Setter Property="Padding" Value="10,8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1.5" CornerRadius="8">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#2563EB"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#9CA3AF"/>
      <Setter Property="Margin" Value="14,2"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="GroupName" Value="nav"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="b" Background="Transparent" CornerRadius="8" Padding="14,11">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#1F2937"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="Background" Value="#2563EB"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="LicItem" TargetType="ListBoxItem">
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="b" Background="Transparent" CornerRadius="8" Padding="12,10" Margin="0,2">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#F3F4F6"/></Trigger>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="b" Property="Background" Value="#EFF6FF"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="250"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- Боковое меню -->
    <Border Background="#111827">
      <DockPanel>
        <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="26,30,20,30">
          <Border Width="40" Height="40" CornerRadius="10" Background="#2563EB">
            <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE8D7;" Foreground="White" FontSize="18"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="Лицензии 1С" Foreground="White" FontWeight="SemiBold" FontSize="17"/>
            <TextBlock Text="без командной строки" Foreground="#6B7280" FontSize="12"/>
          </StackPanel>
        </StackPanel>

        <Border DockPanel.Dock="Bottom" Margin="16,16,16,20" Padding="14" CornerRadius="10" Background="#1F2937">
          <StackPanel>
            <StackPanel Orientation="Horizontal">
              <Ellipse x:Name="AdminDot" Width="8" Height="8" Margin="0,0,8,0" VerticalAlignment="Center"/>
              <TextBlock x:Name="AdminText" Foreground="#E5E7EB" FontSize="13"/>
            </StackPanel>
            <Button x:Name="BtnElevate" Style="{StaticResource BtnSide}" Margin="0,10,0,0" Content="Перезапустить от админа"/>
          </StackPanel>
        </Border>

        <StackPanel>
          <RadioButton x:Name="NavList" Style="{StaticResource Nav}" IsChecked="True">
            <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icon}" Text="&#xE8D7;" Margin="0,1,14,0"/><TextBlock Text="Мои лицензии"/></StackPanel>
          </RadioButton>
          <RadioButton x:Name="NavAct" Style="{StaticResource Nav}">
            <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icon}" Text="&#xE710;" Margin="0,1,14,0"/><TextBlock Text="Активация"/></StackPanel>
          </RadioButton>
          <RadioButton x:Name="NavDiag" Style="{StaticResource Nav}">
            <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icon}" Text="&#xE9D9;" Margin="0,1,14,0"/><TextBlock Text="Диагностика"/></StackPanel>
          </RadioButton>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- Контент -->
    <Grid Grid.Column="1" Margin="34,30,34,28">

      <!-- Страница: Мои лицензии -->
      <Grid x:Name="PageList">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <DockPanel Margin="0,0,0,22">
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="BtnCopy" Style="{StaticResource Btn}">
              <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icon}" Text="&#xE8C8;"/><TextBlock Text="Скопировать всё"/></StackPanel>
            </Button>
            <Button x:Name="BtnFolder" Style="{StaticResource Btn}">
              <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icon}" Text="&#xE838;"/><TextBlock Text="Папка лицензий"/></StackPanel>
            </Button>
            <Button x:Name="BtnRefresh" Style="{StaticResource BtnPrimary}" Margin="0">
              <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icon}" Text="&#xE72C;"/><TextBlock Text="Обновить"/></StackPanel>
            </Button>
          </StackPanel>
          <StackPanel>
            <TextBlock Text="Мои лицензии" Style="{StaticResource H1}"/>
            <TextBlock x:Name="ListSub" Text="Программные лицензии 1С на этом компьютере" Style="{StaticResource Sub}"/>
          </StackPanel>
        </DockPanel>

        <Grid Grid.Row="1">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <Border x:Name="ListBanner" CornerRadius="8" Padding="14,11" Margin="0,0,10,16" Visibility="Collapsed">
            <TextBlock x:Name="ListBannerText" TextWrapping="Wrap" FontWeight="SemiBold"/>
          </Border>
          <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="LicCards" Margin="0,0,10,0"/>
          </ScrollViewer>
          <StackPanel x:Name="LicEmpty" Grid.Row="1" VerticalAlignment="Center" HorizontalAlignment="Center" Visibility="Collapsed" Margin="20">
            <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE8D7;" FontSize="48" Foreground="#D1D5DB" HorizontalAlignment="Center"/>
            <TextBlock Text="Лицензий на этом компьютере нет" Margin="0,16,0,4" FontSize="16" FontWeight="SemiBold" HorizontalAlignment="Center"/>
            <TextBlock Text="Активировать можно в разделе «Активация»" Foreground="#6B7280" FontSize="13" HorizontalAlignment="Center"/>
          </StackPanel>
        </Grid>
      </Grid>

      <!-- Страница: Активация -->
      <Grid x:Name="PageAct" Visibility="Collapsed">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="0,0,10,0">
            <StackPanel Margin="0,0,0,22">
              <TextBlock Text="Активация лицензии" Style="{StaticResource H1}"/>
              <TextBlock Text="Заполните форму — команду для ring соберём сами" Style="{StaticResource Sub}"/>
            </StackPanel>

            <Border Style="{StaticResource Card}" Margin="0,0,0,16">
              <StackPanel>
                <TextBlock Text="Лицензия" Style="{StaticResource H2}"/>
                <TextBlock Text="Рег. номер и пин-код — в конверте или письме с лицензией. «Прошлый пин-код» нужен только при повторной активации." Style="{StaticResource Hint}"/>
                <UniformGrid x:Name="FLic" Columns="3"/>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Card}" Margin="0,0,0,16">
              <StackPanel>
                <TextBlock Text="Владелец" Style="{StaticResource H2}"/>
                <TextBlock Text="Эти данные запоминаются и подставятся в следующий раз." Style="{StaticResource Hint}"/>
                <StackPanel x:Name="FOwnerTop"/>
                <UniformGrid x:Name="FOwner" Columns="2"/>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource Card}" Margin="0,0,0,20">
              <StackPanel>
                <TextBlock Text="Адрес" Style="{StaticResource H2}"/>
                <TextBlock Text="Фактический адрес, где используется программа." Style="{StaticResource Hint}"/>
                <UniformGrid x:Name="FAddr" Columns="3"/>
              </StackPanel>
            </Border>

            <StackPanel Orientation="Horizontal" Margin="0,0,0,16">
              <Button x:Name="BtnActivate" Style="{StaticResource BtnPrimary}" Padding="22,11">
                <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icon}" Text="&#xE8FB;"/><TextBlock Text="Активировать"/></StackPanel>
              </Button>
              <Button x:Name="BtnShowCmd" Style="{StaticResource Btn}" Padding="16,11">
                <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icon}" Text="&#xE756;"/><TextBlock Text="Показать команду"/></StackPanel>
              </Button>
              <Button x:Name="BtnSave" Style="{StaticResource Btn}" Padding="16,11">
                <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icon}" Text="&#xE74E;"/><TextBlock Text="Сохранить данные"/></StackPanel>
              </Button>
            </StackPanel>

            <Border x:Name="ActBanner" CornerRadius="8" Padding="14,11" Margin="0,0,0,16" Visibility="Collapsed">
              <TextBlock x:Name="ActBannerText" TextWrapping="Wrap" FontWeight="SemiBold"/>
            </Border>

            <Border x:Name="ActOutCard" Style="{StaticResource Card}" Padding="18" Visibility="Collapsed" Background="#F9FAFB">
              <TextBox x:Name="ActOut" IsReadOnly="True" BorderThickness="0" Background="Transparent"
                       FontFamily="Consolas" FontSize="13" TextWrapping="Wrap"/>
            </Border>
          </StackPanel>
        </ScrollViewer>
      </Grid>

      <!-- Страница: Диагностика -->
      <Grid x:Name="PageDiag" Visibility="Collapsed">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <DockPanel Margin="0,0,0,22">
          <Button x:Name="BtnDiag" DockPanel.Dock="Right" Style="{StaticResource BtnPrimary}" Margin="0" VerticalAlignment="Center">
            <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Icon}" Text="&#xE72C;"/><TextBlock Text="Проверить снова"/></StackPanel>
          </Button>
          <StackPanel>
            <TextBlock Text="Диагностика" Style="{StaticResource H1}"/>
            <TextBlock Text="Всё ли готово для работы ring" Style="{StaticResource Sub}"/>
          </StackPanel>
        </DockPanel>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="DiagList" Margin="0,0,10,0"/>
        </ScrollViewer>
      </Grid>
    </Grid>

    <!-- Индикатор загрузки -->
    <Grid x:Name="Busy" Grid.ColumnSpan="2" Background="#B3F3F4F6" Visibility="Collapsed">
      <Border Style="{StaticResource Card}" HorizontalAlignment="Center" VerticalAlignment="Center" Padding="32,24">
        <Border.Effect><DropShadowEffect BlurRadius="30" ShadowDepth="6" Opacity="0.15"/></Border.Effect>
        <StackPanel>
          <TextBlock x:Name="BusyText" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,0,0,16"/>
          <ProgressBar IsIndeterminate="True" Width="280" Height="4" Foreground="#2563EB" Background="#E5E7EB" BorderThickness="0"/>
        </StackPanel>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

$win = [Windows.Markup.XamlReader]::Parse($xaml)
foreach ($m in [regex]::Matches($xaml, 'x:Name="(\w+)"')) {
    $n = $m.Groups[1].Value
    $el = $win.FindName($n)
    if ($el) { Set-Variable -Name $n -Value $el -Scope Script }
}

# ---------- Хелперы UI ----------
$script:BC = New-Object Windows.Media.BrushConverter
function Brush([string]$hex) { $script:BC.ConvertFromString($hex) }
function Thick([double]$l, [double]$t, [double]$r, [double]$b) { New-Object Windows.Thickness($l, $t, $r, $b) }
$script:IconFont = New-Object Windows.Media.FontFamily('Segoe MDL2 Assets')
$script:MonoFont = New-Object Windows.Media.FontFamily('Consolas')

function Ask([string]$text, [string]$buttons = 'YesNo', [string]$icon = 'Question') {
    [Windows.MessageBox]::Show($win, $text, 'Лицензии 1С', $buttons, $icon).ToString()
}

function Show-Busy([string]$t) { $BusyText.Text = $t; $Busy.Visibility = 'Visible'; Pump }
function Hide-Busy { if ($script:Busy) { $script:Busy.Visibility = 'Collapsed' } }

$script:BannerKinds = @{
    ok   = @('#DCFCE7', '#166534')
    err  = @('#FEE2E2', '#991B1B')
    warn = @('#FEF3C7', '#92400E')
    info = @('#EFF6FF', '#1E40AF')
}
function Set-Banner($border, $tb, $kind, [string]$text) {
    if (-not $kind) { $border.Visibility = 'Collapsed'; return }
    $c = $script:BannerKinds[$kind]
    $border.Background = Brush $c[0]
    $tb.Foreground = Brush $c[1]
    $tb.Text = $text
    $border.Visibility = 'Visible'
}

function New-SelectableText([string]$text) {
    $t = New-Object Windows.Controls.TextBox
    $t.Text = $text; $t.IsReadOnly = $true; $t.BorderThickness = Thick 0 0 0 0
    $t.Background = [Windows.Media.Brushes]::Transparent; $t.TextWrapping = 'Wrap'; $t.Padding = Thick 0 0 0 0
    $t
}

function Show-KV($panel, [string]$text) {
    $panel.Children.Clear()
    foreach ($ln in ($text -split "`r?`n")) {
        $l = $ln.Trim()
        if (-not $l) { continue }
        $g = New-Object Windows.Controls.Grid
        $g.Margin = Thick 0 0 0 12
        $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = New-Object Windows.GridLength(230)
        $c2 = New-Object Windows.Controls.ColumnDefinition
        $g.ColumnDefinitions.Add($c1); $g.ColumnDefinitions.Add($c2)
        $i = $l.IndexOf(': ')
        if ($i -gt 0 -and $i -lt 70) {
            $k = New-Object Windows.Controls.TextBlock
            $k.Text = $l.Substring(0, $i).Trim(); $k.Foreground = Brush '#6B7280'; $k.TextWrapping = 'Wrap'; $k.Margin = Thick 0 0 14 0
            $v = New-SelectableText ($l.Substring($i + 2).Trim())
            [Windows.Controls.Grid]::SetColumn($v, 1)
            [void]$g.Children.Add($k); [void]$g.Children.Add($v)
        } else {
            $v = New-SelectableText $l
            [Windows.Controls.Grid]::SetColumnSpan($v, 2)
            [void]$g.Children.Add($v)
        }
        [void]$panel.Children.Add($g)
    }
}

function Restart-Elevated {
    if (-not $env:RINGGUI_PATH) {
        [void](Ask 'Закройте программу и запустите RingGUI.cmd правой кнопкой → «Запуск от имени администратора».' 'OK' 'Information')
        return
    }
    try { Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\conhost.exe') -ArgumentList (Get-LaunchArgs) -Verb RunAs | Out-Null; $win.Close() } catch { }  # отказ в UAC — просто остаёмся
}

# Аргументы для запуска без мелькающих окон: conhost --headless powershell ...
function Get-LaunchArgs {
    $p = $env:RINGGUI_PATH.Replace("'", "''")
    "--headless powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"`$env:RINGGUI_PATH='$p'; iex ([IO.File]::ReadAllText(`$env:RINGGUI_PATH, [Text.Encoding]::UTF8))`""
}

# Ярлык на рабочем столе: запуск без единого окна терминала
function Ensure-Shortcut {
    if (-not $env:RINGGUI_PATH) { return }
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Лицензии 1С.lnk'
    if (Test-Path $lnk) { return }
    $sh = New-Object -ComObject WScript.Shell
    $s = $sh.CreateShortcut($lnk)
    $s.TargetPath = Join-Path $env:SystemRoot 'System32\conhost.exe'
    $s.Arguments = Get-LaunchArgs
    $s.WorkingDirectory = Split-Path $env:RINGGUI_PATH
    $s.IconLocation = (Join-Path $env:SystemRoot 'System32\shell32.dll') + ',47'
    $s.Description = 'Лицензии 1С'
    $s.Save()
    $script:ShortcutCreated = $true
}

function Confirm-Admin([string]$what) {
    if ($script:IsAdmin) { return $true }
    $a = Ask ("Для действия «$what» нужны права администратора.`n`nДа — перезапустить программу от администратора`nНет — всё равно попробовать без прав`nОтмена — ничего не делать") 'YesNoCancel' 'Warning'
    if ($a -eq 'Yes') { Restart-Elevated; return $false }
    return ($a -eq 'No')
}

function Test-Ring {
    if ($script:RingPath) { return $true }
    $script:RingPath = Find-Ring
    if ($script:RingPath) { return $true }
    [void](Ask "Утилита ring не найдена на этом компьютере.`n`nОткрою «Диагностику» — там написано, что установить." 'OK' 'Warning')
    $NavDiag.IsChecked = $true
    return $false
}

# ---------- Навигация ----------
function Show-Page($p) {
    foreach ($x in @($PageList, $PageAct, $PageDiag)) { $x.Visibility = 'Collapsed' }
    $p.Visibility = 'Visible'
}
$NavList.Add_Checked({ Show-Page $PageList })
$NavAct.Add_Checked({ Show-Page $PageAct })
$NavDiag.Add_Checked({ Safe { Show-Page $PageDiag; if ($DiagList.Children.Count -eq 0) { Run-Diag } } })

if ($script:IsAdmin) {
    $AdminDot.Fill = Brush '#22C55E'; $AdminText.Text = 'Права администратора'; $BtnElevate.Visibility = 'Collapsed'
} else {
    $AdminDot.Fill = Brush '#F59E0B'; $AdminText.Text = 'Обычные права'
}
$BtnElevate.Add_Click({ Safe { Restart-Elevated } })

# ---------- Мои лицензии: всё сразу на одном экране ----------
$script:AllInfo = ''

function New-LicCard([string]$name, [string]$rest, $info) {
    $card = New-Object Windows.Controls.Border
    $card.Style = $win.FindResource('Card'); $card.Margin = Thick 0 0 0 16
    $root = New-Object Windows.Controls.StackPanel

    # Шапка: иконка, номер лицензии, кнопка «Проверить»
    $head = New-Object Windows.Controls.DockPanel
    $head.Margin = Thick 0 0 0 16
    $btn = New-Object Windows.Controls.Button
    $btn.Style = $win.FindResource('Btn'); $btn.Margin = Thick 0 0 0 0; $btn.VerticalAlignment = 'Top'
    $btn.Content = 'Проверить'
    [Windows.Controls.DockPanel]::SetDock($btn, 'Right')

    $circle = New-Object Windows.Controls.Border
    $circle.Width = 44; $circle.Height = 44; $circle.CornerRadius = New-Object Windows.CornerRadius(22)
    $circle.Background = Brush '#EFF6FF'; $circle.VerticalAlignment = 'Top'
    $ic = New-Object Windows.Controls.TextBlock
    $ic.FontFamily = $script:IconFont; $ic.Text = [string][char]0xE8D7; $ic.FontSize = 18
    $ic.Foreground = Brush '#2563EB'; $ic.HorizontalAlignment = 'Center'; $ic.VerticalAlignment = 'Center'
    $circle.Child = $ic
    [Windows.Controls.DockPanel]::SetDock($circle, 'Left')

    $titles = New-Object Windows.Controls.StackPanel
    $titles.VerticalAlignment = 'Center'; $titles.Margin = Thick 14 0 12 0
    $t1 = New-Object Windows.Controls.TextBlock
    $t1.Text = $name; $t1.FontSize = 18; $t1.FontWeight = [Windows.FontWeights]::SemiBold; $t1.TextWrapping = 'Wrap'
    [void]$titles.Children.Add($t1)
    if ($rest.Trim()) {
        $t2 = New-Object Windows.Controls.TextBlock
        $t2.Text = $rest.Trim(); $t2.FontSize = 12; $t2.Foreground = Brush '#6B7280'; $t2.TextWrapping = 'Wrap'; $t2.Margin = Thick 0 3 0 0
        [void]$titles.Children.Add($t2)
    }
    [void]$head.Children.Add($btn); [void]$head.Children.Add($circle); [void]$head.Children.Add($titles)
    [void]$root.Children.Add($head)

    # Плашка с результатом проверки
    $banner = New-Object Windows.Controls.Border
    $banner.CornerRadius = New-Object Windows.CornerRadius(8); $banner.Padding = Thick 14 11 14 11; $banner.Margin = Thick 0 0 0 14
    $banner.Visibility = 'Collapsed'
    $bt = New-Object Windows.Controls.TextBlock
    $bt.TextWrapping = 'Wrap'; $bt.FontWeight = [Windows.FontWeights]::SemiBold
    $banner.Child = $bt
    [void]$root.Children.Add($banner)

    $sep = New-Object Windows.Controls.Border
    $sep.Height = 1; $sep.Background = Brush '#E5E7EB'; $sep.Margin = Thick 0 0 0 16
    [void]$root.Children.Add($sep)

    # Все сведения из ring license info
    $body = New-Object Windows.Controls.StackPanel
    if ($info.Code -ne 0) { Set-Banner $banner $bt 'err' "Не удалось прочитать лицензию (код $($info.Code))." }
    Show-KV $body (Format-Result $info)
    [void]$root.Children.Add($body)

    $btn.Tag = @{ Name = $name; Banner = $banner; Text = $bt }
    $btn.Add_Click({ param($s, $e) Invoke-Validate $s.Tag })
    $card.Child = $root
    $card
}

function Invoke-Validate($ctx) {
    try {
        Show-Busy "Проверяю лицензию $($ctx.Name)…"
        $r = Invoke-Ring @('license', 'validate', '--name', $ctx.Name)
        Hide-Busy
        if ($r.Code -eq 0) { Set-Banner $ctx.Banner $ctx.Text 'ok' '✓  Лицензия действительна на этом компьютере.' }
        else {
            $why = ((Format-Result $r) -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 2) -join ' '
            Set-Banner $ctx.Banner $ctx.Text 'err' "✕  Проверка не пройдена (код $($r.Code)): $why"
        }
    } catch { Hide-Busy; Show-Error $_ }
}

function Refresh-List {
    if (-not (Test-Ring)) { return }
    Set-Banner $ListBanner $ListBannerText $null ''
    $LicCards.Children.Clear()
    $LicEmpty.Visibility = 'Collapsed'
    $script:AllInfo = ''
    Show-Busy 'Читаю список лицензий…'
    $r = Invoke-Ring @('license', 'list')
    if ($r.Code -ne 0) {
        Hide-Busy
        Set-Banner $ListBanner $ListBannerText 'err' "Не получилось прочитать список лицензий (код $($r.Code)). Чего не хватает — видно в «Диагностике»."
        $err = New-Object Windows.Controls.StackPanel
        Show-KV $err (Format-Result $r)
        $c = New-Object Windows.Controls.Border
        $c.Style = $win.FindResource('Card'); $c.Child = $err
        [void]$LicCards.Children.Add($c)
        return
    }
    $items = @()
    foreach ($ln in ($r.Out -split "`r?`n")) {
        $t = $ln.Trim()
        if ($t -match '^(\S+)\s*(.*)$') { $items += , @($Matches[1].Trim('"'), $Matches[2]) }
    }
    $all = New-Object Text.StringBuilder
    $i = 0
    foreach ($it in $items) {
        $i++
        $BusyText.Text = "Читаю лицензию $i из $($items.Count)…"; Pump
        $info = Invoke-Ring @('license', 'info', '--name', $it[0])
        [void]$LicCards.Children.Add((New-LicCard $it[0] $it[1] $info))
        [void]$all.AppendLine("===== $($it[0]) =====")
        [void]$all.AppendLine((Format-Result $info))
        [void]$all.AppendLine()
    }
    Hide-Busy
    $script:AllInfo = $all.ToString()
    $cnt = $items.Count
    $LicEmpty.Visibility = $(if ($cnt) { 'Collapsed' } else { 'Visible' })
    $ListSub.Text = $(if ($cnt) { "Лицензий на этом компьютере: $cnt  ·  обновлено в $(Get-Date -Format 'HH:mm')" } else { 'На этом компьютере нет активированных лицензий' })
}

$BtnRefresh.Add_Click({ Safe { Refresh-List } })

$BtnCopy.Add_Click({ Safe {
    if (-not $script:AllInfo) { Set-Banner $ListBanner $ListBannerText 'warn' 'Пока нечего копировать — лицензий не найдено.'; return }
    [Windows.Clipboard]::SetText($script:AllInfo)
    Set-Banner $ListBanner $ListBannerText 'ok' 'Сведения обо всех лицензиях скопированы — можно вставить в письмо или документ.'
} })

$BtnFolder.Add_Click({ Safe {
    if (Test-Path $LicDir) { Start-Process explorer.exe $LicDir }
    else { [void](Ask "Папки $LicDir пока нет — значит, лицензий на компьютере ещё не активировали." 'OK' 'Information') }
} })
# ---------- Активация ----------
$script:Boxes = @{}; $script:Required = @{}; $script:Labels = @{}; $script:FieldOrder = @()
$script:SecretKeys = @('pin', 'previous-pin')

function New-Field($panel, [string]$key, [string]$label, [bool]$req) {
    $sp = New-Object Windows.Controls.StackPanel
    $sp.Margin = Thick 0 0 16 16
    $lb = New-Object Windows.Controls.TextBlock
    $lb.FontSize = 13; $lb.Foreground = Brush '#374151'; $lb.Margin = Thick 0 0 0 6
    $lb.Inlines.Add((New-Object Windows.Documents.Run($label)))
    if ($req) { $star = New-Object Windows.Documents.Run(' *'); $star.Foreground = Brush '#DC2626'; $lb.Inlines.Add($star) }
    $tb = New-Object Windows.Controls.TextBox
    $tb.Style = $win.FindResource('Input')
    $tb.Add_TextChanged({ $this.BorderBrush = Brush '#D1D5DB' })
    [void]$sp.Children.Add($lb); [void]$sp.Children.Add($tb)
    [void]$panel.Children.Add($sp)
    $script:Boxes[$key] = $tb; $script:Required[$key] = $req; $script:Labels[$key] = $label
    $script:FieldOrder += $key
}

New-Field $FLic      'serial'       'Рег. номер'       $true
New-Field $FLic      'pin'          'Пин-код'          $true
New-Field $FLic      'previous-pin' 'Прошлый пин-код'  $false
New-Field $FOwnerTop 'company'      'Организация'      $true
New-Field $FOwner    'last-name'    'Фамилия'          $true
New-Field $FOwner    'first-name'   'Имя'              $true
New-Field $FOwner    'middle-name'  'Отчество'         $false
New-Field $FOwner    'email'        'E-mail'           $true
New-Field $FAddr     'country'      'Страна'           $true
New-Field $FAddr     'zip-code'     'Индекс'           $true
New-Field $FAddr     'region'       'Регион'           $false
New-Field $FAddr     'district'     'Район'            $false
New-Field $FAddr     'town'         'Город'            $true
New-Field $FAddr     'street'       'Улица'            $true
New-Field $FAddr     'house'        'Дом'              $true
New-Field $FAddr     'building'     'Корпус / строение' $false
New-Field $FAddr     'apartment'    'Квартира / офис'  $false
$Boxes['country'].Text = 'Россия'

function Get-ActivateArgs {
    $a = @('license', 'activate')
    foreach ($k in $script:FieldOrder) {
        $v = $script:Boxes[$k].Text.Trim()
        if ($v) { $a += "--$k"; $a += $v }
    }
    $a
}

function Test-Required {
    $missing = @()
    foreach ($k in $script:FieldOrder) {
        if ($script:Required[$k] -and -not $script:Boxes[$k].Text.Trim()) {
            $missing += $script:Labels[$k]
            $script:Boxes[$k].BorderBrush = Brush '#DC2626'
        }
    }
    $mail = $script:Boxes['email'].Text.Trim()
    if ($mail -and $mail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
        $missing += 'E-mail (проверьте адрес)'
        $script:Boxes['email'].BorderBrush = Brush '#DC2626'
    }
    if ($missing) {
        Set-Banner $ActBanner $ActBannerText 'warn' ('Заполните: ' + ($missing -join ', '))
        return $false
    }
    $true
}

function Save-Profile {
    $o = [ordered]@{}
    foreach ($k in $script:FieldOrder) { if ($script:SecretKeys -notcontains $k) { $o[$k] = $script:Boxes[$k].Text.Trim() } }
    if (-not (Test-Path $ProfileDir)) { New-Item -ItemType Directory -Path $ProfileDir | Out-Null }
    $o | ConvertTo-Json | Set-Content -Path $ProfileFile -Encoding UTF8
}

function Load-Profile {
    if (-not (Test-Path $ProfileFile)) { return }
    try {
        $o = Get-Content $ProfileFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $o.PSObject.Properties) {
            if ($script:Boxes.ContainsKey($p.Name) -and $p.Value) { $script:Boxes[$p.Name].Text = [string]$p.Value }
        }
    } catch { Write-Log "profile: $_" }
}

function Show-ActOutput([string]$text) { $ActOut.Text = $text; $ActOutCard.Visibility = 'Visible' }

$BtnShowCmd.Add_Click({ Safe {
    Show-ActOutput ('ring ' + (Build-RingArgs (Get-ActivateArgs)))
    Set-Banner $ActBanner $ActBannerText 'info' 'Эту же команду можно выполнить вручную в командной строке от имени администратора.'
} })

$BtnSave.Add_Click({ Safe {
    Save-Profile
    Set-Banner $ActBanner $ActBannerText 'ok' 'Данные владельца и адрес сохранены. Пин-коды не сохраняются.'
} })

$BtnActivate.Add_Click({ Safe {
    if (-not (Test-Ring)) { return }
    if (-not (Test-Required)) { return }
    if (-not (Confirm-Admin 'активация лицензии')) { return }
    Save-Profile
    Set-Banner $ActBanner $ActBannerText $null ''
    Show-Busy 'Активирую лицензию через сервер 1С… это может занять до минуты'
    $r = Invoke-Ring (Get-ActivateArgs)
    Hide-Busy
    Show-ActOutput (Format-Result $r)
    if ($r.Code -eq 0) {
        Set-Banner $ActBanner $ActBannerText 'ok' '✓  Готово! Лицензия активирована и появилась в разделе «Мои лицензии».'
        $Boxes['pin'].Text = ''; $Boxes['previous-pin'].Text = ''
        Refresh-List
    } else {
        Set-Banner $ActBanner $ActBannerText 'err' ("✕  Активация не удалась (код $($r.Code)). Частые причины: пин-код уже использован — возьмите следующий из конверта, а старый впишите в «Прошлый пин-код»; нет интернета; опечатка в рег. номере.")
    }
} })

# ---------- Диагностика ----------
$UrlJava = 'https://bell-sw.com/pages/downloads/'
$UrlRing = 'https://releases.1c.ru/project/EnterpriseLicenseTools'

$StepsPath = @(
    'Нажмите кнопку «Открыть переменные среды» ниже (или Win+R → sysdm.cpl → вкладка «Дополнительно» → «Переменные среды»).',
    'В верхнем списке («Переменные среды пользователя») выберите Path и нажмите «Изменить».',
    'Нажмите «Создать» и впишите  %JAVA_HOME%\bin  (или полный путь к папке bin внутри Java).',
    'Нажмите ОК во всех окнах.',
    'Вернитесь сюда и нажмите «Проверить снова».'
)
$StepsJavaHome = @(
    'Нажмите кнопку «Открыть переменные среды» ниже (или Win+R → sysdm.cpl → вкладка «Дополнительно» → «Переменные среды»).',
    'В верхнем блоке нажмите «Создать».',
    'Имя переменной:  JAVA_HOME',
    'Значение: папка, куда установлена Java, БЕЗ \bin на конце — например  C:\Program Files\BellSoft\LibericaJDK-21',
    'Нажмите ОК во всех окнах, вернитесь сюда и нажмите «Проверить снова».'
)
$StepsJava = @(
    'Нажмите «Скачать Java» ниже — откроется сайт BellSoft (Liberica JDK, бесплатно).',
    'Выберите версию 21 LTS, Windows, x86 64-bit, пакет JDK, формат MSI — и скачайте.',
    'Запустите установщик. На шаге выбора компонентов включите «Add to PATH» и «Set JAVA_HOME variable».',
    'Вернитесь сюда и нажмите «Проверить снова».'
)
$StepsRing = @(
    'Нажмите «Скачать ring» ниже — откроется releases.1c.ru. Войдите под логином портала 1С:ИТС.',
    'Откройте последнюю версию и скачайте дистрибутив для Windows.',
    'Распакуйте архив в любую папку.',
    'Щёлкните правой кнопкой по файлу 1ce-installer.cmd → «Запуск от имени администратора» и подтвердите установку.',
    'Вернитесь сюда и нажмите «Проверить снова».'
)

function Get-SystemPathDirs {
    $raw = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    $raw -split ';' | Where-Object { $_.Trim() } | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_.Trim()) }
}
function Find-JavaInSystemPath {
    foreach ($d in Get-SystemPathDirs) { if (Test-Path (Join-Path $d 'java.exe')) { return $d } }
    return $null
}
function Find-JavaHomes {
    $roots = @("$env:ProgramFiles\BellSoft", "$env:ProgramFiles\Java", "$env:ProgramFiles\Eclipse Adoptium",
               "$env:ProgramFiles\Microsoft", "$env:ProgramFiles\Zulu", "$env:ProgramFiles\Amazon Corretto",
               (Join-Path $env:USERPROFILE '.jdks'))
    $found = @()
    $p = Find-JavaInSystemPath
    if ($p) { $found += (Split-Path $p) }
    foreach ($r in $roots) {
        if (-not (Test-Path $r)) { continue }
        foreach ($d in Get-ChildItem $r -Directory -ErrorAction SilentlyContinue) {
            if (Test-Path (Join-Path $d.FullName 'bin\java.exe')) { $found += $d.FullName }
        }
    }
    $found | Select-Object -Unique
}

# Запись в переменные пользователя через реестр — так не портятся записи вида %VAR% в Path
function Set-UserEnv([string]$name, [string]$value, [string]$kind = 'String') {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    $key.SetValue($name, $value, [Microsoft.Win32.RegistryValueKind]$kind); $key.Close()
    # Оповестить Windows об изменении (новые окна сразу увидят переменные)
    [Environment]::SetEnvironmentVariable('RINGGUI_REFRESH', '1', 'User')
    [Environment]::SetEnvironmentVariable('RINGGUI_REFRESH', $null, 'User')
}
function Add-ToUserPath([string]$dir) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false)
    $cur = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames); $key.Close()
    if (($cur -split ';' | ForEach-Object { $_.Trim().TrimEnd('\') }) -contains $dir.TrimEnd('\')) { return }
    $new = if ($cur.Trim()) { $cur.TrimEnd(';') + ';' + $dir } else { $dir }
    Set-UserEnv 'Path' $new 'ExpandString'
    $env:Path = "$dir;$env:Path"
}

function Fix-JavaPath {
    Add-ToUserPath (Join-Path $env:JAVA_HOME 'bin')
    [void](Ask "Готово: папка Java добавлена в PATH.`nВ новых окнах командной строки java и ring теперь будут работать." 'OK' 'Information')
}
function Fix-JavaHome {
    $homes = @(Find-JavaHomes)
    if (-not $homes) {
        [void](Ask 'Не нашёл установленную Java. Сначала установите её — кнопка «Скачать Java» в карточке выше.' 'OK' 'Warning')
        return
    }
    $h = $homes | Sort-Object -Descending | Select-Object -First 1
    Set-UserEnv 'JAVA_HOME' $h
    $env:JAVA_HOME = $h
    $env:Path = (Join-Path $h 'bin') + ";$env:Path"
    [void](Ask "Готово: JAVA_HOME = $h" 'OK' 'Information')
}
function Open-EnvVars { Start-Process rundll32.exe 'sysdm.cpl,EditEnvironmentVariables' }

function New-ActionButton($act) {
    $b = New-Object Windows.Controls.Button
    $b.Style = $win.FindResource($(if ($act.Primary) { 'BtnPrimary' } else { 'Btn' }))
    $b.Margin = Thick 0 0 8 8; $b.Padding = Thick 14 7 14 7; $b.FontSize = 13
    $sp = New-Object Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'
    if ($act.Icon) {
        $ic = New-Object Windows.Controls.TextBlock
        $ic.FontFamily = $script:IconFont; $ic.Text = [string][char]$act.Icon; $ic.Margin = Thick 0 1 8 0; $ic.VerticalAlignment = 'Center'
        [void]$sp.Children.Add($ic)
    }
    $tx = New-Object Windows.Controls.TextBlock; $tx.Text = $act.Text
    [void]$sp.Children.Add($tx)
    $b.Content = $sp
    $b.Tag = $act
    $b.Add_Click({ param($s, $e) Invoke-DiagAction $s.Tag })
    $b
}
function Invoke-DiagAction($act) {
    try {
        if ($act.Url) { Start-Process $act.Url; return }
        if ($act.Do) { & $act.Do }
        if ($act.Recheck) { Run-Diag }
    } catch { Hide-Busy; Show-Error $_ }
}

function Add-DiagRow([string]$state, [string]$title, [string]$detail, $actions = @(), $steps = @()) {
    $b = New-Object Windows.Controls.Border
    $b.Style = $win.FindResource('Card'); $b.Margin = Thick 0 0 0 10; $b.Padding = Thick 20 16 20 16
    $g = New-Object Windows.Controls.Grid
    $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = New-Object Windows.GridLength(28)
    $c2 = New-Object Windows.Controls.ColumnDefinition
    $g.ColumnDefinitions.Add($c1); $g.ColumnDefinitions.Add($c2)
    $dot = New-Object Windows.Shapes.Ellipse
    $dot.Width = 12; $dot.Height = 12; $dot.VerticalAlignment = 'Top'; $dot.HorizontalAlignment = 'Left'; $dot.Margin = Thick 0 5 0 0
    $dot.Fill = Brush $(switch ($state) { 'ok' { '#22C55E' } 'err' { '#EF4444' } 'warn' { '#F59E0B' } default { '#9CA3AF' } })
    $sp = New-Object Windows.Controls.StackPanel
    $t1 = New-Object Windows.Controls.TextBlock; $t1.Text = $title; $t1.FontWeight = [Windows.FontWeights]::SemiBold
    [void]$sp.Children.Add($t1)
    if ($detail) {
        $t2 = New-SelectableText $detail
        $t2.Foreground = Brush '#6B7280'; $t2.FontSize = 13; $t2.Margin = Thick 0 4 0 0
        [void]$sp.Children.Add($t2)
    }

    $stepsBox = $null
    if ($steps -and $steps.Count) {
        $stepsBox = New-Object Windows.Controls.Border
        $stepsBox.Background = Brush '#F9FAFB'; $stepsBox.BorderBrush = Brush '#E5E7EB'; $stepsBox.BorderThickness = Thick 1 1 1 1
        $stepsBox.CornerRadius = New-Object Windows.CornerRadius(8); $stepsBox.Padding = Thick 16 14 16 6; $stepsBox.Margin = Thick 0 6 0 4
        $stepsBox.Visibility = 'Collapsed'
        $list = New-Object Windows.Controls.StackPanel
        $n = 0
        foreach ($s in $steps) {
            $n++
            $row = New-Object Windows.Controls.Grid; $row.Margin = Thick 0 0 0 10
            $r1 = New-Object Windows.Controls.ColumnDefinition; $r1.Width = New-Object Windows.GridLength(30)
            $r2 = New-Object Windows.Controls.ColumnDefinition
            $row.ColumnDefinitions.Add($r1); $row.ColumnDefinitions.Add($r2)
            $num = New-Object Windows.Controls.Border
            $num.Width = 20; $num.Height = 20; $num.CornerRadius = New-Object Windows.CornerRadius(10); $num.Background = Brush '#DBEAFE'
            $num.VerticalAlignment = 'Top'; $num.HorizontalAlignment = 'Left'; $num.Margin = Thick 0 1 0 0
            $nt = New-Object Windows.Controls.TextBlock
            $nt.Text = [string]$n; $nt.FontSize = 11; $nt.FontWeight = [Windows.FontWeights]::SemiBold; $nt.Foreground = Brush '#1E40AF'
            $nt.HorizontalAlignment = 'Center'; $nt.VerticalAlignment = 'Center'
            $num.Child = $nt
            $st = New-SelectableText $s; $st.FontSize = 13
            [Windows.Controls.Grid]::SetColumn($st, 1)
            [void]$row.Children.Add($num); [void]$row.Children.Add($st)
            [void]$list.Children.Add($row)
        }
        $stepsBox.Child = $list
    }

    if (($actions -and $actions.Count) -or $stepsBox) {
        $wrap = New-Object Windows.Controls.WrapPanel
        $wrap.Margin = Thick 0 12 0 0
        foreach ($a in $actions) { [void]$wrap.Children.Add((New-ActionButton $a)) }
        if ($stepsBox) {
            $tg = New-ActionButton @{ Text = 'Как сделать вручную'; Icon = 0xE70D }
            $tg.Tag = $stepsBox
            $tg.Add_Click({ param($s, $e) $s.Tag.Visibility = $(if ($s.Tag.Visibility -eq 'Visible') { 'Collapsed' } else { 'Visible' }) })
            [void]$wrap.Children.Add($tg)
        }
        [void]$sp.Children.Add($wrap)
        if ($stepsBox) { [void]$sp.Children.Add($stepsBox) }
    }

    [Windows.Controls.Grid]::SetColumn($sp, 1)
    [void]$g.Children.Add($dot); [void]$g.Children.Add($sp)
    $b.Child = $g
    [void]$DiagList.Children.Add($b)
}

function Run-Diag {
    $DiagList.Children.Clear()
    Show-Busy 'Проверяю, всё ли установлено…'
    $envBtn = @{ Text = 'Открыть переменные среды'; Icon = 0xE713; Do = { Open-EnvVars } }

    if ($script:IsAdmin) { Add-DiagRow 'ok' 'Права администратора' 'Есть.' }
    else { Add-DiagRow 'warn' 'Обычные права' 'Смотреть лицензии можно. Для активации нужны права администратора.' @(@{ Text = 'Перезапустить от админа'; Icon = 0xE7EF; Do = { Restart-Elevated } }) }

    # Java
    $homeOk  = $env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME 'bin\java.exe'))
    $inPath  = Find-JavaInSystemPath
    $ver = ''
    $j = Invoke-Cmd 'java -version'
    if ($j.Code -eq 0) { $ver = (($j.Err + "`n" + $j.Out).Trim() -split "`r?`n" | Select-Object -First 1) }

    if ($inPath) {
        Add-DiagRow 'ok' 'Java установлена' ("$ver`n$inPath").Trim()
    } elseif ($homeOk) {
        Add-DiagRow 'warn' 'Java есть, но не добавлена в PATH' ("$ver`nНайдена через JAVA_HOME. Этой программе этого хватает, но если запускать ring из командной строки — он Java не увидит.").Trim() `
            @(@{ Text = 'Добавить в PATH автоматически'; Icon = 0xE73E; Primary = $true; Do = { Fix-JavaPath }; Recheck = $true }, $envBtn) $StepsPath
    } else {
        Add-DiagRow 'err' 'Java не найдена' 'Нужна 64-битная Java 11 или новее — без неё ring не запускается.' `
            @(@{ Text = 'Скачать Java'; Icon = 0xE896; Primary = $true; Url = $UrlJava }) $StepsJava
    }

    # JAVA_HOME
    if ($homeOk) {
        Add-DiagRow 'ok' 'JAVA_HOME настроен' $env:JAVA_HOME
    } elseif ($env:JAVA_HOME) {
        Add-DiagRow 'err' 'JAVA_HOME указывает не туда' "$env:JAVA_HOME — в этой папке нет bin\java.exe." `
            @(@{ Text = 'Исправить автоматически'; Icon = 0xE73E; Primary = $true; Do = { Fix-JavaHome }; Recheck = $true }, $envBtn) $StepsJavaHome
    } else {
        Add-DiagRow 'warn' 'JAVA_HOME не задан' 'Обычно не страшно, если Java есть в PATH. Но некоторым программам (и ring тоже) так надёжнее.' `
            @(@{ Text = 'Настроить автоматически'; Icon = 0xE73E; Primary = $true; Do = { Fix-JavaHome }; Recheck = $true }, $envBtn) $StepsJavaHome
    }

    # ring
    $script:RingPath = Find-Ring
    if ($script:RingPath) {
        Add-DiagRow 'ok' 'Утилита ring найдена' $script:RingPath
        $t = Invoke-Ring @('license', 'list')
        if ($t.Code -eq 0) { Add-DiagRow 'ok' 'ring работает' 'Список лицензий читается без ошибок.' }
        else { Add-DiagRow 'err' "ring запускается с ошибкой (код $($t.Code))" (Format-Result $t) @(@{ Text = 'Переустановить ring'; Icon = 0xE896; Url = $UrlRing }) $StepsRing }
    } else {
        Add-DiagRow 'err' 'Утилита ring не найдена' 'Это «Утилита администрирования лицензий» 1С — именно она умеет читать файлы лицензий.' `
            @(@{ Text = 'Скачать ring с releases.1c.ru'; Icon = 0xE896; Primary = $true; Url = $UrlRing }) $StepsRing
    }

    # Папка лицензий
    if (Test-Path $LicDir) {
        $n = @(Get-ChildItem $LicDir -Filter *.lic -ErrorAction SilentlyContinue).Count
        Add-DiagRow 'info' 'Папка лицензий' "$LicDir — файлов лицензий: $n" @(@{ Text = 'Открыть папку'; Icon = 0xE838; Do = { Start-Process explorer.exe $LicDir } })
    } else {
        Add-DiagRow 'info' 'Папка лицензий' "$LicDir — пока не создана (появится после первой активации)."
    }
    Hide-Busy
}
$BtnDiag.Add_Click({ Safe { Run-Diag } })

# ---------- Старт ----------
Load-Profile
try { Ensure-Shortcut } catch { Write-Log "shortcut: $_" }
$win.Add_ContentRendered({ Safe {
    if ($script:RingPath) { Refresh-List }
    else { $NavDiag.IsChecked = $true }
} })
[void]$win.ShowDialog()
