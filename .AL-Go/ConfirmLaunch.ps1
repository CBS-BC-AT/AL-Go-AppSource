Add-Type -AssemblyName System.Windows.Forms
$message = "WARNING: The selected launch configuration will deploy to a productive environment.`n`nDo you want to proceed?"
$result = [System.Windows.Forms.MessageBox]::Show($message, 'Confirmation', 'YesNo', 'Question')

if ($result -ne 'Yes') {
  Write-Output "Launch cancelled by user."
  exit 1
}
