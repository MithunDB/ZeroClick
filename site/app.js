const modes = {
  shift: { title: 'Convert', caption: 'Hold Shift while dragging a file in Finder.', actions: ['PNG', 'JPG', 'PDF', 'WebP', 'HEIC', 'TIFF', 'AVIF', 'BMP'] },
  tools: { title: 'Tools', caption: 'Hold Shift + Option for tools matched to your files.', actions: ['Upscale', 'Make searchable', 'Crop', 'Resize', 'Edit photo', 'Compress', 'Create PDF', 'Collage'] },
  actions: { title: 'File actions', caption: 'Hold Command for file and privacy actions.', actions: ['Copy path', 'Duplicate', 'Move', 'Redact', 'Encrypt', 'Decrypt', 'Hide message', 'Reveal message'] },
  ai: { title: 'AI · Coming later', caption: 'The AI wheel is a disabled preview. No AI backend runs.', actions: ['Summarize', 'Explain', 'Transcribe', 'Describe', 'Ask AI', 'Translate', 'Organize', 'Draft'] }
};
const wheel = document.getElementById('wheel');
const title = document.getElementById('wheel-title');
const subtitle = document.getElementById('wheel-subtitle');
const caption = document.getElementById('mode-description');
let currentMode = 'shift';
function renderWheel(mode) {
  currentMode = mode;
  const config = modes[mode];
  wheel.replaceChildren();
  title.textContent = config.title;
  subtitle.textContent = mode === 'ai' ? 'Coming later' : 'Choose an action';
  caption.textContent = config.caption;
  for (const [index, name] of config.actions.entries()) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'wheel-action';
    button.style.setProperty('--i', index);
    button.setAttribute('aria-label', `${name}${mode === 'ai' ? ', coming later' : ', preview only'}`);
    button.innerHTML = `<span>${name}</span>`;
    if (mode === 'ai') button.disabled = true;
    else {
      button.addEventListener('mouseenter', () => selectAction(name, button));
      button.addEventListener('focus', () => selectAction(name, button));
      button.addEventListener('click', () => selectAction(name, button));
    }
    wheel.append(button);
  }
  document.querySelectorAll('.mode').forEach(button => {
    const active = button.dataset.mode === mode;
    button.classList.toggle('active', active);
    button.setAttribute('aria-pressed', String(active));
  });
}
function selectAction(name, button) {
  wheel.querySelectorAll('.wheel-action').forEach(item => item.classList.remove('selected'));
  button.classList.add('selected');
  title.textContent = name;
  subtitle.textContent = 'Preview only';
}
document.querySelectorAll('.mode').forEach(button => button.addEventListener('click', () => renderWheel(button.dataset.mode)));
renderWheel('shift');
const observer = new IntersectionObserver(entries => {
  for (const entry of entries) if (entry.isIntersecting) { entry.target.classList.add('in-view'); observer.unobserve(entry.target); }
}, { threshold: 0.12 });
document.querySelectorAll('.feature-card, .steps li, .section-heading').forEach(element => observer.observe(element));
