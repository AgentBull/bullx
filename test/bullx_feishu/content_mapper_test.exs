defmodule BullXFeishu.ContentMapperTest do
  use ExUnit.Case, async: true

  alias BullXGateway.Delivery.Content
  alias BullXFeishu.{Config, ContentMapper}

  setup do
    {:ok, config} =
      Config.normalize({:feishu, "default"}, %{
        app_id: "cli_test",
        app_secret: "secret_test"
      })

    {:ok, config: config}
  end

  test "maps Feishu text content to a Gateway text block", %{config: config} do
    assert {:ok, [%Content{kind: :text, body: %{"text" => "hello"}}]} =
             ContentMapper.from_message(
               %{
                 "message_id" => "om_1",
                 "message_type" => "text",
                 "content" => Jason.encode!(%{"text" => "hello"})
               },
               config
             )
  end

  test "maps Feishu file content to a resource URI with fallback text", %{config: config} do
    assert {:ok, [%Content{kind: :file, body: body}]} =
             ContentMapper.from_message(
               %{
                 "message_id" => "om_1",
                 "message_type" => "file",
                 "content" => %{"file_key" => "file_x", "file_name" => "report.pdf"}
               },
               config
             )

    assert body["url"] == "feishu://message-resource/om_1/file_x"
    assert body["fallback_text"] == "report.pdf"
  end

  test "renders unsupported outbound media as fallback text" do
    content = %Content{
      kind: :image,
      body: %{"url" => "feishu://message-resource/om_1/img", "fallback_text" => "[image]"}
    }

    assert {:ok, rendered, ["image_degraded_to_fallback_text"]} =
             ContentMapper.render_outbound(content)

    assert rendered.msg_type == "text"
    assert Jason.decode!(rendered.content) == %{"text" => "[image]"}
  end
end
