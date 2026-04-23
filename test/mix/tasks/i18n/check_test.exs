defmodule Mix.Tasks.I18n.CheckTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @tag :tmp_dir
  test "fails when a translation drops variables used in MF2 function options", %{
    tmp_dir: tmp_dir
  } do
    File.write!(
      Path.join(tmp_dir, "en-US.toml"),
      """
      [checkout]
      summary = "Checkout {$total :currency currency=$currency}"
      """
    )

    File.write!(
      Path.join(tmp_dir, "zh-Hans-CN.toml"),
      """
      [checkout]
      summary = "结算 {$total :currency currency=USD}"
      """
    )

    Mix.Task.reenable("i18n.check")

    output =
      capture_io(:stderr, fn ->
        assert {:shutdown, 1} =
                 catch_exit(Mix.Tasks.I18n.Check.run(["--dir", tmp_dir]))
      end)

    assert output =~ ~s(key "checkout.summary" — missing variables: currency)
  end
end
